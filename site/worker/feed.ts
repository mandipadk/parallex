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

/** Released versions ("0.19.0"), for telling real versions from made-up ones. */
async function releasedVersions(env: Env, ctx: ExecutionContext): Promise<Set<string>> {
  const body = await fromGitHub(`/repos/${REPO}/releases?per_page=100`, "releases", env, ctx, 3600)
  try {
    const releases = JSON.parse(body ?? "[]") as { tag_name?: string }[]
    return new Set(releases.map((r) => (r.tag_name ?? "").replace(/^v/, "")).filter(Boolean))
  } catch {
    return new Set()
  }
}

/**
 * The update check: GitHub's latest release, passed through unchanged (the
 * app verifies every update's signature itself, so this server can't hand
 * out a bad one), and one count per check.
 */
export async function latestRelease(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const body = await fromGitHub(`/repos/${REPO}/releases/latest`, "latest", env, ctx, 300)
  if (!body) return new Response("GitHub didn't answer", { status: 502 })
  ctx.waitUntil(record(request, env, ctx))
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

async function record(request: Request, env: Env, ctx: ExecutionContext): Promise<void> {
  // A burst from one address isn't a Mac checking once a day. The address
  // is used for this and never stored.
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown"
  if (env.CHECKS_LIMIT && !(await env.CHECKS_LIMIT.limit({ key: address })).success) return
  const { version, os, arch, periods } = describe(request.headers, await releasedVersions(env, ctx))
  const day = new Date().toISOString().slice(0, 10)
  const statement = env.DB.prepare(
    `INSERT INTO checks (day, version, os, arch, period, count) VALUES (?1, ?2, ?3, ?4, ?5, 1)
     ON CONFLICT (day, version, os, arch, period) DO UPDATE SET count = count + 1`,
  )
  await env.DB.batch(periods.map((period) => statement.bind(day, version, os, arch, period)))
}
