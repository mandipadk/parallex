import { dashboardPage, signInPage } from "./admin"
import { isSignedIn, signIn, signOutEverywhere } from "./auth"
import { collect, kofi } from "./collect"
import { compatibilityList, type IssueReport } from "./compatibility"
import { latestLab } from "./lab"
import type { Env } from "./env"
import { latestRelease, loadRollout, publishedReleases, versionOf, type Rollout } from "./feed"
import { apps, community, crashes, exportCSV, growth, logAction, overview, releases, windowOf } from "./mission"
import { summarize } from "./summary"
import { report, retain } from "./report"
import { usage } from "./usage"

// Mission Control: the site's own Worker handles /api and /admin; every
// other request is the site, served from its assets.

const html = (body: string, status = 200, headers: Record<string, string> = {}) =>
  new Response(body, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Frame-Options": "DENY",
      "Referrer-Policy": "no-referrer",
      ...headers,
    },
  })

const redirect = (to: string, headers: Record<string, string> = {}) =>
  new Response(null, { status: 303, headers: { Location: to, "Cache-Control": "no-store", ...headers } })

/** Forms post only from this site (the cookie is SameSite=Strict too).
 *  Browsers say where a request came from in Sec-Fetch-Site; without it,
 *  the Origin must be this host. */
function sameOrigin(request: Request): boolean {
  const site = request.headers.get("Sec-Fetch-Site")
  if (site) return site === "same-origin" || site === "none"
  const origin = request.headers.get("Origin")
  if (origin === null) return true
  try {
    return new URL(origin).host === request.headers.get("Host")
  } catch {
    return false // "null" and other opaque origins
  }
}

/**
 * Steering the newest release: `share` (to a percentage of Macs), `pause`,
 * `resume`, `pull` (no one gets it, whatever its share) and `restore`.
 * Only released versions are accepted.
 */
async function changeRollout(env: Env, ctx: ExecutionContext, action: string, version: string, percent: number): Promise<void> {
  const released = new Set((await publishedReleases(env, ctx)).map(versionOf))
  if (action !== "start" && !released.has(version)) return
  const rollout: Rollout = await loadRollout(env)
  switch (action) {
    case "start":
      if (![10, 100].includes(percent)) return
      rollout.startPercent = percent
      break
    case "share":
      if (![1, 10, 25, 50, 100].includes(percent)) return
      Object.assign(rollout, { version, percent, paused: false })
      break
    case "pause":
      Object.assign(rollout, { version, paused: true, percent: rollout.version === version ? rollout.percent : 100 })
      break
    case "resume":
      if (rollout.version === version) rollout.paused = false
      break
    case "pull":
      if (!rollout.pulled.includes(version)) rollout.pulled.push(version)
      break
    case "restore":
      rollout.pulled = rollout.pulled.filter((v) => v !== version)
      break
    default:
      return
  }
  await env.DB.prepare(`INSERT INTO settings (key, value) VALUES ('rollout', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1`)
    .bind(JSON.stringify(rollout)).run()
  await logAction(env, `rollout ${action}`, action === "start" ? `New releases start at ${percent}%` : `${version}${action === "share" ? ` to ${percent}%` : ""}`)
}

/** Adding a GitHub report to the public list, or taking it off. Only
 *  reports collected from GitHub, with an app line, can be added. */
async function reviewReport(env: Env, action: string, issue: number): Promise<void> {
  if (!Number.isInteger(issue)) return
  if (action === "remove") {
    await env.DB.prepare(`DELETE FROM approved_reports WHERE issue = ?1`).bind(issue).run()
    await logAction(env, "report removed", `#${issue}`)
    return
  }
  if (action !== "approve") return
  const kept = await env.DB.prepare(`SELECT body FROM feed WHERE key = 'compat-issues'`).first<{ body: string }>()
  let issues: IssueReport[] = []
  try {
    issues = JSON.parse(kept?.body ?? "[]") as IssueReport[]
  } catch {
    return
  }
  const report = issues.find((r) => r.issue === issue)
  if (!report?.bundleID || !report.verdict) return
  await env.DB.prepare(
    `INSERT OR REPLACE INTO approved_reports (issue, bundle_id, name, app_version, verdict, url, approved_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
  ).bind(issue, report.bundleID, report.name ?? report.bundleID, report.version ?? "", report.verdict, report.url, new Date().toISOString()).run()
  await logAction(env, "report approved", `#${issue} ${report.name ?? report.bundleID}: ${report.verdict}`)
}

/** Putting an app on the public list under a name, or taking it off. */
async function listApp(env: Env, action: string, bundle: string, name: string): Promise<void> {
  if (!/^[A-Za-z0-9][A-Za-z0-9.-]{1,99}$/.test(bundle)) return
  if (action === "remove") {
    await env.DB.prepare(`DELETE FROM listed_apps WHERE bundle_id = ?1`).bind(bundle).run()
    await logAction(env, "app unlisted", bundle)
  } else if (action === "add" && name.trim() && name.length <= 60) {
    await env.DB.prepare(`INSERT OR REPLACE INTO listed_apps (bundle_id, name, listed_at) VALUES (?1, ?2, ?3)`)
      .bind(bundle, name.trim(), new Date().toISOString()).run()
    await logAction(env, "app listed", `${name.trim()} (${bundle})`)
  }
}

/** After an action: the dashboard's own requests want an answer, forms a
 *  page to go back to. */
const done = (request: Request, to: string) =>
  (request.headers.get("Accept") ?? "").includes("application/json") ? Response.json({ ok: true }) : redirect(to)

const json = (body: unknown) => Response.json(body, { headers: { "Cache-Control": "no-store" } })

/** Mission Control's page (src/admin), built with the site. */
async function dashboard(request: Request, env: Env): Promise<Response> {
  // Assets may answer /admin.html with a redirect to /admin: ask for both.
  let page = await env.ASSETS.fetch(new Request(new URL("/admin", request.url)))
  if (!page.ok) page = await env.ASSETS.fetch(new Request(new URL("/admin.html", request.url), { redirect: "manual" }))
  if (!page.ok) return html(dashboardPage(await summarize(env, { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext)))
  return html(await page.text())
}

async function admin(request: Request, env: Env, ctx: ExecutionContext, path: string): Promise<Response> {
  if (request.method === "POST" && !sameOrigin(request)) return new Response("Forbidden", { status: 403 })
  if (path === "/admin/sign-in" && request.method === "POST") {
    const address = request.headers.get("CF-Connecting-IP") ?? "unknown"
    if (env.SIGN_IN_LIMIT && !(await env.SIGN_IN_LIMIT.limit({ key: address })).success) {
      return new Response("Too many tries. Wait a minute.", { status: 429 })
    }
    const form = await request.formData().catch(() => null)
    const cookie = await signIn(String(form?.get("token") ?? ""), env)
    return cookie ? redirect("/admin", { "Set-Cookie": cookie }) : redirect("/admin?failed=1")
  }
  if (!(await isSignedIn(request, env))) {
    return html(signInPage(new URL(request.url).searchParams.has("failed"), Boolean(env.ADMIN_TOKEN)), 401)
  }
  if (path === "/admin/sign-out" && request.method === "POST") {
    return redirect("/admin", { "Set-Cookie": await signOutEverywhere(env) })
  }
  if (path === "/admin/release" && request.method === "POST") {
    const form = await request.formData().catch(() => null)
    await changeRollout(env, ctx, String(form?.get("action") ?? ""), String(form?.get("version") ?? ""), Number(form?.get("percent")))
    return done(request, "/admin#releases")
  }
  if (path === "/admin/list" && request.method === "POST") {
    const form = await request.formData().catch(() => null)
    await listApp(env, String(form?.get("action") ?? ""), String(form?.get("bundle") ?? ""), String(form?.get("name") ?? ""))
    return done(request, "/admin#apps")
  }
  if (path === "/admin/report" && request.method === "POST") {
    const form = await request.formData().catch(() => null)
    await reviewReport(env, String(form?.get("action") ?? ""), Number(form?.get("issue")))
    return done(request, "/admin#reports")
  }
  if (path === "/admin/collect" && request.method === "POST") {
    await collect(env)
    await logAction(env, "collected", "GitHub numbers and reports")
    return done(request, "/admin")
  }
  if (request.method === "GET" && path.startsWith("/admin/api/")) {
    const days = windowOf(request)
    switch (path.slice("/admin/api/".length)) {
      case "overview": return json(await overview(env, ctx, days))
      case "releases": return json(await releases(env, ctx, days))
      case "crashes": return json(await crashes(env, days))
      case "apps": return json(await apps(env, days))
      case "growth": return json(await growth(env, days))
      case "community": return json(await community(env))
    }
    return new Response("Not found", { status: 404 })
  }
  const exported = /^\/admin\/export\/([a-z]+)\.csv$/.exec(path)
  if (exported && request.method === "GET") return exportCSV(env, exported[1])
  if (path === "/admin/summary.json") {
    return Response.json(await summarize(env, ctx), { headers: { "Cache-Control": "no-store" } })
  }
  if (path === "/admin/classic") {
    return html(dashboardPage(await summarize(env, ctx)))
  }
  if (path === "/admin" || path === "/admin/") {
    return dashboard(request, env)
  }
  return new Response("Not found", { status: 404 })
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const path = new URL(request.url).pathname
    if (path === "/api/v1/releases/latest" && request.method === "GET") return latestRelease(request, env, ctx)
    if (path === "/api/v1/kofi" && request.method === "POST") return kofi(request, env)
    if (path === "/api/v1/usage" && request.method === "POST") return usage(request, env, ctx)
    if (path === "/api/v2/report" && request.method === "POST") return report(request, env, ctx)
    if (path === "/api/v1/compatibility" && request.method === "GET") {
      // Worked out at most every ten minutes per data center.
      const key = "https://parallex.mandip.dev/__cache/compatibility"
      const cached = await caches.default.match(key)
      if (cached) return cached
      const response = Response.json(
        await Promise.all([compatibilityList(env, request), latestLab()]).then(([apps, lab]) => ({
          generated: new Date().toISOString(), apps, lab,
        })),
        { headers: { "Cache-Control": "public, max-age=600", "Access-Control-Allow-Origin": "*" } },
      )
      ctx.waitUntil(caches.default.put(key, response.clone()))
      return response
    }
    if (path === "/admin" || path.startsWith("/admin/")) return admin(request, env, ctx, path)
    if (path.startsWith("/api/")) return new Response("Not found", { status: 404 })
    return env.ASSETS.fetch(request)
  },

  async scheduled(_controller, env, ctx) {
    // Independent: GitHub being down mustn't keep old rows past 90 days.
    ctx.waitUntil(Promise.allSettled([collect(env), retain(env)]).then(() => undefined))
  },
} satisfies ExportedHandler<Env>
