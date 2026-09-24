import { dashboardPage, signInPage } from "./admin"
import { isSignedIn, signIn, signOutEverywhere } from "./auth"
import { collect, kofi } from "./collect"
import { compatibilityList, type IssueReport } from "./compatibility"
import type { Env } from "./env"
import { latestRelease, loadRollout, publishedReleases, versionOf, type Rollout } from "./feed"
import { summarize } from "./summary"
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
}

/** Adding a GitHub report to the public list, or taking it off. Only
 *  reports collected from GitHub, with an app line, can be added. */
async function reviewReport(env: Env, action: string, issue: number): Promise<void> {
  if (!Number.isInteger(issue)) return
  if (action === "remove") {
    await env.DB.prepare(`DELETE FROM approved_reports WHERE issue = ?1`).bind(issue).run()
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
}

/** Putting an app on the public list under a name, or taking it off. */
async function listApp(env: Env, action: string, bundle: string, name: string): Promise<void> {
  if (!/^[A-Za-z0-9][A-Za-z0-9.-]{1,99}$/.test(bundle)) return
  if (action === "remove") {
    await env.DB.prepare(`DELETE FROM listed_apps WHERE bundle_id = ?1`).bind(bundle).run()
  } else if (action === "add" && name.trim() && name.length <= 60) {
    await env.DB.prepare(`INSERT OR REPLACE INTO listed_apps (bundle_id, name, listed_at) VALUES (?1, ?2, ?3)`)
      .bind(bundle, name.trim(), new Date().toISOString()).run()
  }
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
    return redirect("/admin#releases")
  }
  if (path === "/admin/list" && request.method === "POST") {
    const form = await request.formData().catch(() => null)
    await listApp(env, String(form?.get("action") ?? ""), String(form?.get("bundle") ?? ""), String(form?.get("name") ?? ""))
    return redirect("/admin#apps")
  }
  if (path === "/admin/report" && request.method === "POST") {
    const form = await request.formData().catch(() => null)
    await reviewReport(env, String(form?.get("action") ?? ""), Number(form?.get("issue")))
    return redirect("/admin#reports")
  }
  if (path === "/admin/collect" && request.method === "POST") {
    await collect(env)
    return redirect("/admin")
  }
  if (path === "/admin/summary.json") {
    return Response.json(await summarize(env, ctx), { headers: { "Cache-Control": "no-store" } })
  }
  if (path === "/admin" || path === "/admin/") {
    return html(dashboardPage(await summarize(env, ctx)))
  }
  return new Response("Not found", { status: 404 })
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const path = new URL(request.url).pathname
    if (path === "/api/v1/releases/latest" && request.method === "GET") return latestRelease(request, env, ctx)
    if (path === "/api/v1/kofi" && request.method === "POST") return kofi(request, env)
    if (path === "/api/v1/usage" && request.method === "POST") return usage(request, env, ctx)
    if (path === "/api/v1/compatibility" && request.method === "GET") {
      // Worked out at most every ten minutes per data center.
      const key = "https://parallex.mandip.dev/__cache/compatibility"
      const cached = await caches.default.match(key)
      if (cached) return cached
      const response = Response.json(
        { generated: new Date().toISOString(), apps: await compatibilityList(env, request) },
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
    ctx.waitUntil(collect(env).then(() => undefined))
  },
} satisfies ExportedHandler<Env>
