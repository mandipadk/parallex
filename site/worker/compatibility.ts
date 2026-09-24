import type { Env } from "./env"

const REPO = "mandipadk/parallex"

export type Verdict = "works" | "problems" | "broken"

/** A compatibility report from GitHub, read from its issue form. */
export interface IssueReport {
  issue: number
  url: string
  title: string
  verdict: Verdict | null
  name: string | null
  version: string | null
  bundleID: string | null
}

/** The form's answers: "### How does it work?" and the "App: …" setup line. */
export function parseIssue(issue: { number: number; html_url: string; title: string; body?: string | null }): IssueReport {
  const body = issue.body ?? ""
  const answer = body.match(/###\s*How does it work\?\s*\n+([^\n]+)/i)?.[1]?.trim().toLowerCase() ?? ""
  const verdict: Verdict | null = answer.startsWith("works great") ? "works"
    : answer.startsWith("works, with") ? "problems"
    : answer.startsWith("doesn") ? "broken" : null
  const app = body.match(/^App:\s*(.+?)\s+([0-9][^\s(]*)(?:\s*\(([A-Za-z0-9.-]+)\))?\s*$/m)
  return {
    issue: issue.number, url: issue.html_url, title: issue.title, verdict,
    name: app?.[1]?.slice(0, 60) ?? null, version: app?.[2]?.slice(0, 30) ?? null, bundleID: app?.[3] ?? null,
  }
}

/** Reports from GitHub, newest first (collected with the other numbers). */
export async function fetchIssueReports(env: Env): Promise<IssueReport[] | null> {
  const response = await fetch(`https://api.github.com/repos/${REPO}/issues?labels=compatibility&state=all&per_page=50`, {
    headers: {
      Accept: "application/vnd.github+json", "User-Agent": "parallex-server",
      ...(env.GITHUB_TOKEN ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` } : {}),
    },
  })
  if (!response.ok) return null
  const issues = (await response.json()) as { number: number; html_url: string; title: string; body?: string | null; pull_request?: unknown }[]
  return issues.filter((i) => !i.pull_request).map(parseIssue)
}

export interface ListedApp {
  bundleID: string
  name: string
  verdict: Verdict
  /** Usage reports in 90 days (weekly, so not a count of Macs), and those
   *  whose copies quit at launch or passed an isolation check. */
  reports90: number
  failing: number
  verified: number
  reports: { issue: number; url: string; verdict: string; version: string }[]
  notice: string | null
}

type Notice = { bundleID: string; level: string; message: string; versions?: string }

/**
 * The public list: only apps the maintainer listed (under the name they
 * chose) or with an approved GitHub report, with what usage reports and the
 * signed notices say about them. Usage reports alone never put an app here.
 */
export async function compatibilityList(env: Env, request: Request): Promise<ListedApp[]> {
  const since = new Date(Date.now() - 89 * 86_400_000).toISOString().slice(0, 10)
  const [listed, usage, reports] = await env.DB.batch<Record<string, unknown>>([
    env.DB.prepare(`SELECT bundle_id, name FROM listed_apps`),
    env.DB.prepare(
      `SELECT bundle_id, SUM(macs) AS reports, SUM(failing_macs) AS failing, SUM(verified_macs) AS verified
       FROM usage_apps WHERE day >= ?1 AND bundle_id IN (SELECT bundle_id FROM listed_apps UNION SELECT bundle_id FROM approved_reports)
       GROUP BY bundle_id`,
    ).bind(since),
    env.DB.prepare(`SELECT issue, bundle_id, name, app_version, verdict, url FROM approved_reports ORDER BY issue DESC`),
  ])
  let notices: Notice[] = []
  try {
    const file = await env.ASSETS.fetch(new Request(new URL("/advisories.json", request.url)))
    notices = file.ok ? ((await file.json()) as { apps?: Notice[] }).apps ?? [] : []
  } catch {
    notices = []
  }

  const apps = new Map<string, ListedApp>()
  const entry = (bundleID: string, name: string) => {
    const existing = apps.get(bundleID)
    if (existing) return existing
    const created: ListedApp = { bundleID, name, verdict: "works", reports90: 0, failing: 0, verified: 0, reports: [], notice: null }
    apps.set(bundleID, created)
    return created
  }
  for (const row of listed.results) entry(String(row.bundle_id), String(row.name))
  for (const row of reports.results) {
    entry(String(row.bundle_id), String(row.name)).reports.push({
      issue: Number(row.issue), url: String(row.url), verdict: String(row.verdict), version: String(row.app_version),
    })
  }
  for (const row of usage.results) {
    const app = apps.get(String(row.bundle_id))
    if (!app) continue
    app.reports90 = Number(row.reports)
    app.failing = Number(row.failing)
    app.verified = Number(row.verified)
  }
  for (const notice of notices) {
    const app = apps.get(notice.bundleID)
    if (app && !app.notice) app.notice = notice.message
  }

  const rank: Record<Verdict, number> = { works: 0, problems: 1, broken: 2 }
  for (const app of apps.values()) {
    const shares = app.reports90 ? app.failing / app.reports90 : 0
    let verdict: Verdict = shares >= 0.5 ? "broken" : shares >= 0.15 ? "problems" : "works"
    // The newest approved report and the notices can only make it worse.
    const latest = app.reports[0]?.verdict as Verdict | undefined
    if (latest && rank[latest] > rank[verdict]) verdict = latest
    const notice = notices.find((n) => n.bundleID === app.bundleID)
    if (notice?.level === "unsupported") verdict = "broken"
    else if (notice && verdict === "works") verdict = "problems"
    app.verdict = verdict
  }
  return [...apps.values()].sort((a, b) => b.reports90 - a.reports90 || a.name.localeCompare(b.name))
}
