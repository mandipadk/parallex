import { fetchIssueReports } from "./compatibility"
import type { Env } from "./env"

const REPO = "mandipadk/parallex"
const SPONSOR = "mandipadk"

/** Today's numbers from GitHub, kept one value per key per day. */
export async function collect(env: Env): Promise<Record<string, number>> {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "User-Agent": "parallex-server",
    ...(env.GITHUB_TOKEN ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}),
  }
  const get = async <T>(path: string): Promise<T | null> => {
    const response = await fetch(`https://api.github.com${path}`, { headers })
    return response.ok ? ((await response.json()) as T) : null
  }
  const values: Record<string, number> = {}

  const repo = await get<{ stargazers_count: number; open_issues_count: number }>(`/repos/${REPO}`)
  if (repo) {
    values.stars = repo.stargazers_count
    values.open_issues = repo.open_issues_count
  }

  type Release = { tag_name: string; assets: { name: string; download_count: number }[] }
  const releases = await get<Release[]>(`/repos/${REPO}/releases?per_page=100`)
  if (releases) {
    let dmg = 0
    let zip = 0
    for (const release of releases) {
      let total = 0
      for (const asset of release.assets) {
        if (asset.name.endsWith(".dmg")) dmg += asset.download_count
        // The zip is what updates and the Terminal installer download.
        if (asset.name.endsWith(".zip")) zip += asset.download_count
        if (asset.name.endsWith(".dmg") || asset.name.endsWith(".zip")) total += asset.download_count
      }
      values[`downloads:${release.tag_name}`] = total
    }
    values.downloads_dmg = dmg
    values.downloads_zip = zip
  }

  const reports = await get<{ total_count: number }>(
    `/search/issues?q=${encodeURIComponent(`repo:${REPO} label:compatibility`)}&per_page=1`,
  )
  if (reports) values.compat_reports = reports.total_count

  if (env.GITHUB_TOKEN) {
    const response = await fetch("https://api.github.com/graphql", {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify({
        query: `{ user(login: "${SPONSOR}") { sponsors(first: 1) { totalCount } monthlyEstimatedSponsorsIncomeInCents } }`,
      }),
    })
    if (response.ok) {
      const body = (await response.json()) as {
        data?: { user?: { sponsors?: { totalCount: number }; monthlyEstimatedSponsorsIncomeInCents?: number } }
      }
      const user = body.data?.user
      if (user?.sponsors) values.sponsors = user.sponsors.totalCount
      if (user?.monthlyEstimatedSponsorsIncomeInCents != null) values.sponsors_monthly_cents = user.monthlyEstimatedSponsorsIncomeInCents
    }
  }

  // Compatibility reports, kept for review on the dashboard.
  const issues = await fetchIssueReports(env)
  if (issues) {
    await env.DB.prepare(`INSERT INTO feed (key, body, fetched) VALUES ('compat-issues', ?1, ?2)
      ON CONFLICT (key) DO UPDATE SET body = ?1, fetched = ?2`).bind(JSON.stringify(issues), new Date().toISOString()).run()
  }

  const day = new Date().toISOString().slice(0, 10)
  const statement = env.DB.prepare(
    `INSERT INTO stats (day, key, value) VALUES (?1, ?2, ?3) ON CONFLICT (day, key) DO UPDATE SET value = ?3`,
  )
  const entries = Object.entries(values)
  if (entries.length) await env.DB.batch(entries.map(([key, value]) => statement.bind(day, key, value)))
  return values
}

/**
 * Ko-fi's webhook: a form post whose `data` field is JSON. Only the amount,
 * currency, kind and time are kept (no names, emails or messages).
 */
export async function kofi(request: Request, env: Env): Promise<Response> {
  if (!env.KOFI_TOKEN) return new Response("Not set up", { status: 503 })
  const form = await request.formData().catch(() => null)
  const raw = form?.get("data")
  if (typeof raw !== "string") return new Response("Bad request", { status: 400 })
  let data: { verification_token?: string; message_id?: string; timestamp?: string; type?: string; amount?: string; currency?: string }
  try {
    data = JSON.parse(raw)
  } catch {
    return new Response("Bad request", { status: 400 })
  }
  if (data.verification_token !== env.KOFI_TOKEN) return new Response("Forbidden", { status: 403 })
  const cents = Math.round(Number.parseFloat(data.amount ?? "0") * 100)
  if (!data.message_id || !Number.isFinite(cents)) return new Response("Bad request", { status: 400 })
  await env.DB.prepare(
    `INSERT OR IGNORE INTO donations (id, source, kind, amount_cents, currency, at) VALUES (?1, 'ko-fi', ?2, ?3, ?4, ?5)`,
  )
    .bind(data.message_id, (data.type ?? "Donation").slice(0, 40), cents, (data.currency ?? "USD").slice(0, 3).toUpperCase(),
      data.timestamp ?? new Date().toISOString())
    .run()
  return new Response("OK")
}
