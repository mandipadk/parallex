import type { Env } from "./env"
import { publishedReleases, versionOf } from "./feed"

const FEATURES = new Set([
  "workspaces", "throwaway", "hideFromDock", "menuBarIcon", "shortcut", "quitWhenUnused", "openAtLaunch",
  "shareMCPServers", "signInLinks", "webLinks",
])
const WEBSITES = new Set([
  "web.whatsapp.com", "teams.microsoft.com", "outlook.office.com", "mail.google.com", "app.slack.com", "discord.com",
  "www.messenger.com", "web.telegram.org",
])
const KINDS = new Set(["copy", "sandboxed copy", "instance"])
/** New apps a day can add; past it, only apps already seen that day count. */
const NEW_APPS_PER_DAY = 3000

type Report = {
  version?: unknown; apps?: unknown; websites?: unknown; otherWebsites?: unknown; features?: unknown
}
type App = { bundleID?: unknown; name?: unknown; appVersion?: unknown; kind?: unknown; instances?: unknown; quitsAtLaunch?: unknown; verified?: unknown }

const text = (value: unknown, pattern: RegExp, max: number): string | null =>
  typeof value === "string" && value.length <= max && pattern.test(value) ? value : null
const whole = (value: unknown, max: number): number =>
  typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.min(max, Math.floor(value))) : 0

/**
 * The opt-in weekly report: checked, bounded, and added into the day's
 * counts. The report itself isn't kept, and nothing in it names a person.
 */
export async function usage(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  // One report a minute per network (IPv6 by its /64, which one home or
  // office shares), so reports can't be piled up. Never stored.
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown"
  const network = address.includes(":") ? address.split(":").slice(0, 4).join(":") : address
  if (env.USAGE_LIMIT && !(await env.USAGE_LIMIT.limit({ key: network })).success) {
    return new Response("Too many", { status: 429 })
  }
  if (Number(request.headers.get("Content-Length") ?? 0) > 64_000) return new Response("Too large", { status: 413 })
  const body = await request.text()
  if (body.length > 64_000) return new Response("Too large", { status: 413 })
  let report: Report
  try {
    report = JSON.parse(body) as Report
  } catch {
    return new Response("Bad request", { status: 400 })
  }
  const released = new Set((await publishedReleases(env, ctx)).map(versionOf))
  const version = typeof report.version === "string" && released.has(report.version) ? report.version : "other"
  const day = new Date().toISOString().slice(0, 10)
  const statements: D1PreparedStatement[] = [
    env.DB.prepare(`INSERT INTO usage_reports (day, version, macs) VALUES (?1, ?2, 1)
      ON CONFLICT (day, version) DO UPDATE SET macs = macs + 1`).bind(day, version),
  ]

  const seenToday = await env.DB.prepare(`SELECT COUNT(*) AS n FROM usage_apps WHERE day = ?1`).bind(day).first<{ n: number }>()
  const roomForNew = (seenToday?.n ?? 0) < NEW_APPS_PER_DAY
  const apps = Array.isArray(report.apps) ? (report.apps as App[]).slice(0, 60) : []
  for (const app of apps) {
    const bundleID = text(app.bundleID, /^[A-Za-z0-9][A-Za-z0-9.-]{1,99}$/, 100)
    const kind = typeof app.kind === "string" && KINDS.has(app.kind) ? app.kind : null
    if (!bundleID || !kind) continue
    const name = text(app.name, /^[^\u0000-\u001f<>]{1,60}$/u, 60) ?? bundleID
    const appVersion = text(app.appVersion, /^[0-9A-Za-z.() _-]{1,30}$/, 30) ?? "other"
    const upsert = `INSERT INTO usage_apps (day, bundle_id, app_version, kind, name, macs, instances, failing_macs, verified_macs)
      VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?8)
      ON CONFLICT (day, bundle_id, app_version, kind) DO UPDATE SET macs = macs + 1, instances = instances + ?6,
        failing_macs = failing_macs + ?7, verified_macs = verified_macs + ?8`
    const existingOnly = `UPDATE usage_apps SET macs = macs + 1, instances = instances + ?6, failing_macs = failing_macs + ?7,
      verified_macs = verified_macs + ?8 WHERE day = ?1 AND bundle_id = ?2 AND app_version = ?3 AND kind = ?4 AND ?5 IS NOT NULL`
    statements.push(env.DB.prepare(roomForNew ? upsert : existingOnly).bind(
      day, bundleID, appVersion, kind, name, whole(app.instances, 20) || 1, app.quitsAtLaunch === true ? 1 : 0, app.verified === true ? 1 : 0,
    ))
  }

  const features = new Map<string, number>()
  if (report.features && typeof report.features === "object") {
    for (const [feature, value] of Object.entries(report.features as Record<string, unknown>)) {
      if (FEATURES.has(feature)) features.set(feature, whole(value, 100))
    }
  }
  const sites = Array.isArray(report.websites) ? report.websites.filter((w): w is string => typeof w === "string" && WEBSITES.has(w)) : []
  for (const site of new Set(sites)) features.set(`website:${site}`, 1)
  const others = whole(report.otherWebsites, 100)
  if (others) features.set("website:other", others)
  for (const [feature, total] of features) {
    if (!total) continue
    statements.push(env.DB.prepare(`INSERT INTO usage_features (day, feature, macs, total) VALUES (?1, ?2, ?3, ?4)
      ON CONFLICT (day, feature) DO UPDATE SET macs = macs + ?3, total = total + ?4`).bind(day, feature, total > 0 ? 1 : 0, total))
  }
  await env.DB.batch(statements)
  return new Response(null, { status: 204 })
}
