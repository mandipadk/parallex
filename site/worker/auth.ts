import type { Env } from "./env"

const COOKIE = "parallex_admin"
const LIFETIME = 60 * 60 * 24 * 30

async function digest(text: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
}

/** Compares secrets without leaking how much of them matched. */
async function same(a: string, b: string): Promise<boolean> {
  const [x, y] = await Promise.all([digest(a), digest(b)])
  return crypto.subtle.timingSafeEqual(x, y)
}

/** A MAC under the admin token: proves the token was typed without being
 *  the token. Changing the token ends every session. */
async function mac(env: Env, text: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(env.ADMIN_TOKEN ?? ""), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  )
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`parallex mission control ${text}`))
  return btoa(String.fromCharCode(...new Uint8Array(signature))).replace(/[+/=]/g, (c) => ({ "+": "-", "/": "_", "=": "" })[c] ?? "")
}

/** Signing out ends sessions issued before it, on every device. */
async function sessionsAfter(env: Env): Promise<number> {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key = 'sessions_after'`).first<{ value: string }>()
  return Number(row?.value ?? 0)
}

export async function isSignedIn(request: Request, env: Env): Promise<boolean> {
  if (!env.ADMIN_TOKEN) return false
  const cookie = request.headers.get("Cookie") ?? ""
  const value = cookie.split(/;\s*/).find((c) => c.startsWith(`${COOKIE}=`))?.slice(COOKIE.length + 1) ?? ""
  const [issued, signature] = value.split(".")
  const at = Number(issued)
  if (!signature || !Number.isInteger(at)) return false
  const now = Math.floor(Date.now() / 1000)
  if (at > now + 60 || now - at > LIFETIME || at < (await sessionsAfter(env))) return false
  return same(signature, await mac(env, issued))
}

/** A sign-in attempt; the cookie to set when the token is right. */
export async function signIn(token: string, env: Env): Promise<string | null> {
  if (!env.ADMIN_TOKEN || !(await same(token.trim(), env.ADMIN_TOKEN))) return null
  const issued = String(Math.floor(Date.now() / 1000))
  return `${COOKIE}=${issued}.${await mac(env, issued)}; Path=/admin; HttpOnly; Secure; SameSite=Strict; Max-Age=${LIFETIME}`
}

/** Ends every session, this one included. */
export async function signOutEverywhere(env: Env): Promise<string> {
  await env.DB.prepare(`INSERT INTO settings (key, value) VALUES ('sessions_after', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1`)
    .bind(String(Math.floor(Date.now() / 1000) + 1)).run()
  return `${COOKIE}=; Path=/admin; HttpOnly; Secure; SameSite=Strict; Max-Age=0`
}
