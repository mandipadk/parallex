import { dashboardPage, signInPage } from "./admin"
import { isSignedIn, signIn, signOutEverywhere } from "./auth"
import { collect, kofi } from "./collect"
import type { Env } from "./env"
import { latestRelease } from "./feed"
import { summarize } from "./summary"

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

async function admin(request: Request, env: Env, path: string): Promise<Response> {
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
  if (path === "/admin/collect" && request.method === "POST") {
    await collect(env)
    return redirect("/admin")
  }
  if (path === "/admin/summary.json") {
    return Response.json(await summarize(env), { headers: { "Cache-Control": "no-store" } })
  }
  if (path === "/admin" || path === "/admin/") {
    return html(dashboardPage(await summarize(env)))
  }
  return new Response("Not found", { status: 404 })
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const path = new URL(request.url).pathname
    if (path === "/api/v1/releases/latest" && request.method === "GET") return latestRelease(request, env, ctx)
    if (path === "/api/v1/kofi" && request.method === "POST") return kofi(request, env)
    if (path === "/admin" || path.startsWith("/admin/")) return admin(request, env, path)
    if (path.startsWith("/api/")) return new Response("Not found", { status: 404 })
    return env.ASSETS.fetch(request)
  },

  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(collect(env).then(() => undefined))
  },
} satisfies ExportedHandler<Env>
