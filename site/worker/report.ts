import type { Env } from "./env"
import { publishedReleases, versionOf } from "./feed"
import { canonicalProps, crashSignature, EVENTS, GAUGES, whole, type Crash } from "./telemetry"

/**
 * Telemetry 2: the daily report of a Mac that shares usage. Everything is
 * checked against what Parallex sends (names, properties and their values
 * allowed here, nothing else), bounded, and stored with the report's random
 * install number, which is renewed every 180 days and kept 90 (see
 * migrations/0005_telemetry.sql). No names, paths or addresses.
 */

type Report = {
  schema?: unknown; install?: unknown; since?: unknown; version?: unknown; os?: unknown; arch?: unknown
  events?: unknown; gauges?: unknown; crashes?: unknown
}
type Counted = { name?: unknown; props?: unknown; n?: unknown; value?: unknown; version?: unknown }

const INSTALL = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const WEEK = /^20[2-9][0-9]-W(0[1-9]|[1-4][0-9]|5[0-3])$/

/** New install numbers taken a day; beyond it, only Macs already known. */
const NEW_INSTALLS_PER_DAY = 5000
/** New app bundle IDs and website hosts taken a day; beyond it, "other". */
const NEW_NAMES_PER_DAY = 40

/** ISO week of a day ("2026-W40"). */
function weekOf(day: string): string {
  const date = new Date(`${day}T00:00:00Z`)
  const thursday = new Date(date.getTime() + (3 - ((date.getUTCDay() + 6) % 7)) * 86_400_000)
  const jan1 = Date.UTC(thursday.getUTCFullYear(), 0, 1)
  const week = Math.floor((thursday.getTime() - jan1) / (7 * 86_400_000)) + 1
  return `${thursday.getUTCFullYear()}-W${String(week).padStart(2, "0")}`
}

/** Rows in multi-row INSERTs, kept under D1's 100 bound parameters, so a
 *  whole report is a few dozen statements at most. */
function insertRows(env: Env, head: string, columns: number, tail: string, rows: unknown[][]): D1PreparedStatement[] {
  const perStatement = Math.floor(100 / columns)
  const statements: D1PreparedStatement[] = []
  for (let start = 0; start < rows.length; start += perStatement) {
    const chunk = rows.slice(start, start + perStatement)
    const values = chunk.map((_, r) => `(${Array.from({ length: columns }, (_, c) => `?${r * columns + c + 1}`).join(", ")})`).join(", ")
    statements.push(env.DB.prepare(`${head} VALUES ${values} ${tail}`).bind(...chunk.flat()))
  }
  return statements
}

export async function report(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  if (Number(request.headers.get("Content-Length") ?? 0) > 64_000) return new Response("Too large", { status: 413 })
  const body = await request.text()
  if (body.length > 64_000) return new Response("Too large", { status: 413 })
  let parsed: Report
  try {
    parsed = JSON.parse(body) as Report
  } catch {
    return new Response("Bad request", { status: 400 })
  }
  const install = typeof parsed.install === "string" && INSTALL.test(parsed.install) ? parsed.install : null
  if (parsed.schema !== 2 || !install) return new Response("Bad request", { status: 400 })
  // One report a minute per install number, and a looser limit per network
  // (addresses held in memory for a minute, never stored).
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown"
  const network = address.includes(":") ? address.split(":").slice(0, 4).join(":") : address
  if (env.USAGE_LIMIT && !(await env.USAGE_LIMIT.limit({ key: `install:${install}` })).success) {
    return new Response("Too many", { status: 429 })
  }
  if (env.CHECKS_LIMIT && !(await env.CHECKS_LIMIT.limit({ key: `report:${network}` })).success) {
    return new Response("Too many", { status: 429 })
  }

  const day = new Date().toISOString().slice(0, 10)
  const db = env.DB
  const [known, newToday, namesToday] = await db.batch<{ n: number }>([
    db.prepare(`SELECT COUNT(*) AS n FROM installs WHERE install = ?1`).bind(install),
    db.prepare(`SELECT COUNT(*) AS n FROM installs WHERE first_day = ?1`).bind(day),
    db.prepare(`SELECT COUNT(*) AS n FROM known_names WHERE first_day = ?1`).bind(day),
  ])
  const isNew = Number(known.results[0]?.n ?? 0) === 0
  if (isNew && Number(newToday.results[0]?.n ?? 0) >= NEW_INSTALLS_PER_DAY) return new Response("Too many", { status: 429 })

  const released = new Set((await publishedReleases(env, ctx)).map(versionOf))
  const versionOr = (value: unknown, fallback: string) => (typeof value === "string" && released.has(value) ? value : fallback)
  const version = versionOr(parsed.version, "other")
  const os = typeof parsed.os === "string" && /^\d{2}\.\d{1,2}$/.test(parsed.os) ? parsed.os : "other"
  const arch = parsed.arch === "arm64" || parsed.arch === "x86_64" ? parsed.arch : "other"
  const cohort = typeof parsed.since === "string" && WEEK.test(parsed.since) ? parsed.since : "other"
  // A number whose Mac started before this week is a renewed one, not a
  // new Mac (a first report comes the day Parallex is first used).
  const renewed = isNew && cohort !== "other" && cohort < weekOf(day) ? 1 : 0

  // App bundle IDs and website hosts: known ones, and a few new ones a day.
  const events = Array.isArray(parsed.events) ? (parsed.events as Counted[]).slice(0, 200) : []
  const gauges = Array.isArray(parsed.gauges) ? (parsed.gauges as Counted[]).slice(0, 200) : []
  const named = new Set<string>()
  for (const item of [...events, ...gauges]) {
    const app = item.props && typeof item.props === "object" ? (item.props as Record<string, unknown>).app : undefined
    if (typeof app === "string" && app !== "other" && app.length <= 100) named.add(app)
  }
  const names = [...named].slice(0, 60)
  const seen = new Set<string>()
  if (names.length) {
    const found = await db.prepare(`SELECT name FROM known_names WHERE name IN (${names.map((_, i) => `?${i + 1}`).join(", ")})`)
      .bind(...names).all<{ name: string }>()
    for (const row of found.results) seen.add(row.name)
  }
  let room = NEW_NAMES_PER_DAY - Number(namesToday.results[0]?.n ?? 0)
  const taken: string[] = []
  for (const name of names) {
    if (seen.has(name) || room <= 0) continue
    seen.add(name)
    taken.push(name)
    room--
  }
  const withKnownApp = (props: unknown) => {
    if (!props || typeof props !== "object") return props
    const app = (props as Record<string, unknown>).app
    return typeof app === "string" && app !== "other" && !seen.has(app) ? { ...(props as object), app: "other", name: undefined } : props
  }

  const statements: D1PreparedStatement[] = [
    db.prepare(`INSERT INTO installs (install, first_day, last_day, version, os, arch, cohort, renewed) VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7)
      ON CONFLICT (install) DO UPDATE SET last_day = ?2, version = ?3, os = ?4, arch = ?5`).bind(install, day, version, os, arch, cohort, renewed),
    db.prepare(`INSERT INTO install_days (day, install, version, os, arch) VALUES (?1, ?2, ?3, ?4, ?5)
      ON CONFLICT (day, install) DO UPDATE SET version = ?3, os = ?4, arch = ?5`).bind(day, install, version, os, arch),
    // Today's gauges are replaced by this report's.
    db.prepare(`DELETE FROM gauges WHERE day = ?1 AND install = ?2`).bind(day, install),
    ...insertRows(env, `INSERT OR IGNORE INTO known_names (name, first_day)`, 2, "", taken.map((name) => [name, day])),
  ]

  // Events and crashes count against the version they happened on.
  const eventRows = new Map<string, unknown[]>()
  for (const event of events) {
    const name = typeof event.name === "string" ? event.name : ""
    const allowed = EVENTS[name]
    const n = whole(event.n, 1000)
    const props = allowed ? canonicalProps(allowed, withKnownApp(event.props)) : null
    if (!allowed || props === null || !n) continue
    const at = versionOr(event.version, version)
    const key = `${at}\n${name}\n${props}`
    const row = eventRows.get(key)
    if (row) row[6] = Math.min(1000, Number(row[6]) + n)
    else eventRows.set(key, [day, install, at, os, name, props, n])
  }
  statements.push(...insertRows(env, `INSERT INTO events (day, install, version, os, name, props, n)`, 7,
    `ON CONFLICT (day, install, version, name, props) DO UPDATE SET n = n + excluded.n`, [...eventRows.values()]))

  const gaugeRows = new Map<string, unknown[]>()
  for (const gauge of gauges) {
    const name = typeof gauge.name === "string" ? gauge.name : ""
    const allowed = GAUGES[name]
    const value = whole(gauge.value, 10_000)
    const props = allowed ? canonicalProps(allowed, withKnownApp(gauge.props)) : null
    if (!allowed || props === null || value === null) continue
    const key = `${name}\n${props}`
    const row = gaugeRows.get(key)
    if (row) row[5] = Math.min(10_000, Number(row[5]) + value)
    else gaugeRows.set(key, [day, install, version, name, props, value])
  }
  statements.push(...insertRows(env, `INSERT INTO gauges (day, install, version, name, props, value)`, 6,
    `ON CONFLICT (day, install, name, props) DO UPDATE SET value = excluded.value`, [...gaugeRows.values()]))

  const crashes = Array.isArray(parsed.crashes) ? (parsed.crashes as (Crash & { version?: unknown })[]).slice(0, 20) : []
  const crashRows = new Map<string, unknown[]>()
  const signatureRows = new Map<string, unknown[]>()
  for (const crash of crashes) {
    const found = await crashSignature(crash)
    if (!found) continue
    const at = versionOr(crash.version, version)
    const kind = crash.kind as string
    const key = `${at}\n${found.signature}`
    const row = crashRows.get(key)
    const n = whole(crash.n, 100) || 1
    if (row) row[6] = Math.min(100, Number(row[6]) + n)
    else crashRows.set(key, [day, install, at, os, found.signature, kind, n])
    signatureRows.set(found.signature, [found.signature, kind, found.summary, found.frames, day, at])
  }
  statements.push(
    ...insertRows(env, `INSERT INTO crashes (day, install, version, os, signature, kind, n)`, 7,
      `ON CONFLICT (day, install, version, signature) DO UPDATE SET n = n + excluded.n`, [...crashRows.values()]),
    ...[...signatureRows.values()].map((row) =>
      db.prepare(`INSERT INTO crash_signatures (signature, kind, summary, frames, first_day, last_day, first_version, last_version)
        VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, ?6) ON CONFLICT (signature) DO UPDATE SET last_day = ?5, last_version = ?6`).bind(...row)),
  )
  await db.batch(statements)
  return new Response(null, { status: 204 })
}

/**
 * Housekeeping (the cron): days older than 90 are folded into totals that
 * hold no install numbers, then their rows go, and so do install numbers
 * not seen for 90 days.
 */
export async function retain(env: Env, now = new Date()): Promise<void> {
  const cutoff = new Date(now.getTime() - 90 * 86_400_000).toISOString().slice(0, 10)
  await env.DB.batch([
    env.DB.prepare(`INSERT OR REPLACE INTO event_totals (day, version, name, props, installs, total)
      SELECT day, version, name, props, COUNT(DISTINCT install), SUM(n) FROM events WHERE day < ?1
      GROUP BY day, version, name, props`).bind(cutoff),
    env.DB.prepare(`INSERT OR REPLACE INTO install_totals (day, version, os, arch, installs)
      SELECT day, version, os, arch, COUNT(*) FROM install_days WHERE day < ?1 GROUP BY day, version, os, arch`).bind(cutoff),
    env.DB.prepare(`DELETE FROM events WHERE day < ?1`).bind(cutoff),
    env.DB.prepare(`DELETE FROM gauges WHERE day < ?1`).bind(cutoff),
    env.DB.prepare(`DELETE FROM crashes WHERE day < ?1`).bind(cutoff),
    env.DB.prepare(`DELETE FROM install_days WHERE day < ?1`).bind(cutoff),
    env.DB.prepare(`DELETE FROM installs WHERE last_day < ?1`).bind(cutoff),
    env.DB.prepare(`INSERT OR REPLACE INTO mac_totals (day, macs) SELECT day, COUNT(*) FROM mac_days WHERE day < ?1 GROUP BY day`).bind(cutoff),
    env.DB.prepare(`DELETE FROM mac_days WHERE day < ?1`).bind(cutoff),
    env.DB.prepare(`DELETE FROM macs WHERE last_day < ?1`).bind(cutoff),
    // Reply addresses don't outlive 90 days, dealt with or not; notes dealt
    // with go 90 days after they were sent.
    env.DB.prepare(`UPDATE feedback SET contact = NULL WHERE at < ?1 AND contact IS NOT NULL`).bind(cutoff),
    env.DB.prepare(`DELETE FROM feedback WHERE status = 'done' AND at < ?1`).bind(cutoff),
    env.DB.prepare(`DELETE FROM alerts_sent WHERE at < ?1`).bind(cutoff),
  ])
}
