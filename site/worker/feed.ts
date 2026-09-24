import type { Env } from "./env"

const REPO = "mandipadk/parallex"
const PERIODS = new Set(["new", "day", "week", "month"])

function githubHeaders(env: Env): Record<string, string> {
  return {
    Accept: "application/vnd.github+json",
    "User-Agent": "parallex-server",
    ...(env.GITHUB_TOKEN ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}),
  }
}

/**
 * A GitHub answer, from this data center's cache, else GitHub, else the
 * last good copy kept in D1 (GitHub limits how often a shared Cloudflare
 * address may ask). Null only when there has never been a good answer.
 */
async function fromGitHub(path: string, key: string, env: Env, ctx: ExecutionContext, seconds: number): Promise<string | null> {
  const cacheKey = `https://parallex.mandip.dev/__cache/${key}`
  const cached = await caches.default.match(cacheKey)
  if (cached) return cached.text()
  const upstream = await fetch(`https://api.github.com${path}`, { headers: githubHeaders(env) }).catch(() => null)
  if (upstream?.ok) {
    const body = await upstream.text()
    ctx.waitUntil(Promise.all([
      caches.default.put(cacheKey, new Response(body, { headers: { "Cache-Control": `public, max-age=${seconds}` } })),
      env.DB.prepare(`INSERT INTO feed (key, body, fetched) VALUES (?1, ?2, ?3) ON CONFLICT (key) DO UPDATE SET body = ?2, fetched = ?3`)
        .bind(key, body, new Date().toISOString()).run(),
    ]))
    return body
  }
  const kept = await env.DB.prepare(`SELECT body FROM feed WHERE key = ?1`).bind(key).first<{ body: string }>()
  return kept?.body ?? null
}

type GitHubRelease = { tag_name?: string; draft?: boolean; prerelease?: boolean; [key: string]: unknown }

/** Published releases, newest first (GitHub lists them that way). */
export async function publishedReleases(env: Env, ctx: ExecutionContext): Promise<GitHubRelease[]> {
  // (A new key: the 0.20 server cached this list for an hour.)
  const body = await fromGitHub(`/repos/${REPO}/releases?per_page=100`, "releases-v2", env, ctx, 300)
  try {
    return (JSON.parse(body ?? "[]") as GitHubRelease[]).filter((r) => r.tag_name && !r.draft && !r.prerelease)
  } catch {
    return []
  }
}

export const versionOf = (release: GitHubRelease) => String(release.tag_name ?? "").replace(/^v/, "")

/** How a release is going out: to what share of Macs, paused, or pulled. */
export interface Rollout {
  /** The version the share applies to (older releases are out to everyone). */
  version?: string
  percent: number
  paused: boolean
  /** Releases no one gets any more. */
  pulled: string[]
  /** The share a new release starts at, until it's given one of its own. */
  startPercent: number
}

/** The stored rollout; when it can't be read, releases go out as usual. */
export async function loadRollout(env: Env): Promise<Rollout> {
  try {
    const row = await env.DB.prepare(`SELECT value FROM settings WHERE key = 'rollout'`).first<{ value: string }>()
    const stored = JSON.parse(row?.value ?? "{}") as Partial<Rollout>
    return {
      version: stored.version, percent: stored.percent ?? 100, paused: stored.paused ?? false,
      pulled: stored.pulled ?? [], startPercent: stored.startPercent ?? 100,
    }
  } catch {
    return { percent: 100, paused: false, pulled: [], startPercent: 100 }
  }
}

/**
 * The release a Mac should be offered: the newest that isn't pulled, unless
 * it's being rolled out and this Mac isn't in the share yet (or it's
 * paused), in which case the one before it. `bucket` is the 0–99 number the
 * Mac picked at random once; without one (older Parallex, the installer) a
 * Mac waits for the full rollout.
 */
export function choose(releases: GitHubRelease[], rollout: Rollout, bucket: number | null): GitHubRelease | undefined {
  const available = releases.filter((r) => !rollout.pulled.includes(versionOf(r)))
  const [newest, previous] = available
  if (!newest) return undefined
  // A release the rollout doesn't name yet starts at the starting share.
  const steered = versionOf(newest) === rollout.version
  const percent = steered ? rollout.percent : rollout.startPercent
  if (steered && rollout.paused) return previous ?? newest
  if (percent >= 100) return newest
  const included = bucket !== null && bucket < percent
  return included ? newest : previous ?? newest
}

/**
 * The update check: the release this Mac should get, in GitHub's own format
 * (the app verifies every update's signature itself, so this server can't
 * hand out a bad one), and one count per check.
 */
export async function latestRelease(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const [releases, rollout] = await Promise.all([publishedReleases(env, ctx), loadRollout(env)])
  const bucketHeader = request.headers.get("X-Parallex-Bucket")
  const bucket = bucketHeader !== null && /^\d{1,2}$/.test(bucketHeader) ? Number(bucketHeader) : null
  const chosen = choose(releases, rollout, bucket)
  // Every release pulled: nothing is offered (the app doesn't ask GitHub
  // instead). No release list at all (GitHub down, nothing kept yet):
  // GitHub's latest as is.
  if (releases.length && !chosen) {
    ctx.waitUntil(record(request, env, new Set(releases.map(versionOf))))
    return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } })
  }
  const body = chosen ? JSON.stringify(chosen) : await fromGitHub(`/repos/${REPO}/releases/latest`, "latest", env, ctx, 300)
  if (!body) return new Response("GitHub didn't answer", { status: 502 })
  ctx.waitUntil(record(request, env, new Set(releases.map(versionOf))))
  return new Response(body, { headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } })
}

/**
 * What a check says about itself, cleaned up: a version that was never
 * released, a macOS that doesn't exist, or an unknown chip is counted as
 * "other", so nothing free-form is stored and made-up values can't pile up.
 */
export function describe(
  headers: Headers,
  released: Set<string>,
): { version: string; os: string; arch: string; periods: string[] } {
  const version = (headers.get("X-Parallex-Version") ?? "").trim()
  const os = (headers.get("X-Parallex-OS") ?? "").trim()
  const arch = headers.get("X-Parallex-Arch") ?? ""
  const active = (headers.get("X-Parallex-Active") ?? "").split(",").map((p) => p.trim())
  const install = headers.get("X-Parallex-Installer") === "1"
  const [major, minor] = os.split(".").map(Number)
  const realOS = /^\d{2}(\.\d)?$/.test(os) && major >= 11 && major <= 40 && (minor ?? 0) <= 9
  return {
    version: released.has(version) ? version : install ? "installer" : "other",
    os: realOS ? os : "other",
    arch: arch === "arm64" || arch === "x86_64" ? arch : "other",
    periods: install ? ["install"] : ["check", ...PERIODS].filter((p) => p === "check" || active.includes(p)),
  }
}

async function record(request: Request, env: Env, released: Set<string>): Promise<void> {
  // A burst from one address isn't a Mac checking once a day. The address
  // is used for this and never stored.
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown"
  if (env.CHECKS_LIMIT && !(await env.CHECKS_LIMIT.limit({ key: address })).success) return
  const { version, os, arch, periods } = describe(request.headers, released)
  const day = new Date().toISOString().slice(0, 10)
  const statement = env.DB.prepare(
    `INSERT INTO checks (day, version, os, arch, period, count) VALUES (?1, ?2, ?3, ?4, ?5, 1)
     ON CONFLICT (day, version, os, arch, period) DO UPDATE SET count = count + 1`,
  )
  await env.DB.batch(periods.map((period) => statement.bind(day, version, os, arch, period)))
}
