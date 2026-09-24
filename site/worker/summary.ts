import type { Env } from "./env"

export interface Summary {
  generated: string
  active: { day: number; week: number; month: number }
  newThisWeek: number
  installsThisMonth: number
  series: { day: string; active: number; fresh: number }[]
  versions: { name: string; count: number }[]
  os: { name: string; count: number }[]
  arch: { name: string; count: number }[]
  stats: Record<string, number>
  releases: { tag: string; downloads: number }[]
  donations: { kofiCents: number; kofiCount: number; otherCurrencies: string[]; recent: { kind: string; cents: number; currency: string; at: string }[] }
}

const iso = (date: Date) => date.toISOString().slice(0, 10)

function daysAgo(now: Date, days: number): string {
  return iso(new Date(now.getTime() - days * 86_400_000))
}

/** Monday of this week and the 1st of this month (UTC, like the counts). */
function periodStarts(now: Date): { week: string; month: string } {
  const monday = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
  monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7))
  return { week: iso(monday), month: iso(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1))) }
}

export async function summarize(env: Env, now = new Date()): Promise<Summary> {
  const today = iso(now)
  const starts = periodStarts(now)
  const since30 = daysAgo(now, 29)
  const since7 = daysAgo(now, 6)
  const db = env.DB
  const sum = (period: string, since: string) =>
    db.prepare(`SELECT COALESCE(SUM(count), 0) AS n FROM checks WHERE period = ?1 AND day >= ?2`).bind(period, since)
  const breakdown = (column: "version" | "os" | "arch") =>
    db.prepare(
      `SELECT ${column} AS name, SUM(count) AS count FROM checks WHERE period = 'day' AND day >= ?1 GROUP BY ${column} ORDER BY count DESC LIMIT 12`,
    ).bind(since7)

  const [day, week, month, fresh, installs, series, versions, os, arch, stats, kofi, recent] = await db.batch<Record<string, unknown>>([
    sum("day", today),
    sum("week", starts.week),
    sum("month", starts.month),
    sum("new", since7),
    sum("install", starts.month),
    db.prepare(
      `SELECT day, SUM(CASE WHEN period = 'day' THEN count ELSE 0 END) AS active, SUM(CASE WHEN period = 'new' THEN count ELSE 0 END) AS fresh
       FROM checks WHERE day >= ?1 GROUP BY day ORDER BY day`,
    ).bind(since30),
    breakdown("version"),
    breakdown("os"),
    breakdown("arch"),
    db.prepare(`SELECT key, value FROM stats s WHERE day = (SELECT MAX(day) FROM stats WHERE key = s.key)`),
    // The goal is in dollars: other currencies are listed, not added.
    db.prepare(
      `SELECT COALESCE(SUM(CASE WHEN currency = 'USD' THEN amount_cents ELSE 0 END), 0) AS cents, COUNT(*) AS n,
              GROUP_CONCAT(DISTINCT CASE WHEN currency <> 'USD' THEN currency END) AS others
       FROM donations WHERE at >= ?1`,
    ).bind(daysAgo(now, 365)),
    db.prepare(`SELECT kind, amount_cents AS cents, currency, at FROM donations ORDER BY at DESC LIMIT 8`),
  ])

  const n = (result: D1Result<Record<string, unknown>>) => Number(result.results[0]?.n ?? 0)
  const rows = <T>(result: D1Result<Record<string, unknown>>) => result.results as T[]

  // Every day of the last 30 shows, counted or not.
  const byDay = new Map(rows<{ day: string; active: number; fresh: number }>(series).map((r) => [r.day, r]))
  const days = Array.from({ length: 30 }, (_, i) => daysAgo(now, 29 - i))
  const statValues = Object.fromEntries(rows<{ key: string; value: number }>(stats).map((r) => [r.key, Number(r.value)]))

  return {
    generated: now.toISOString(),
    active: { day: n(day), week: n(week), month: n(month) },
    newThisWeek: n(fresh),
    installsThisMonth: n(installs),
    series: days.map((d) => ({ day: d, active: Number(byDay.get(d)?.active ?? 0), fresh: Number(byDay.get(d)?.fresh ?? 0) })),
    versions: rows(versions),
    os: rows(os),
    arch: rows(arch),
    stats: statValues,
    releases: Object.entries(statValues)
      .filter(([key]) => key.startsWith("downloads:"))
      .map(([key, downloads]) => ({ tag: key.slice("downloads:".length), downloads }))
      .sort((a, b) => b.tag.localeCompare(a.tag, undefined, { numeric: true }))
      .slice(0, 10),
    donations: {
      kofiCents: Number(kofi.results[0]?.cents ?? 0),
      kofiCount: Number(kofi.results[0]?.n ?? 0),
      otherCurrencies: String(kofi.results[0]?.others ?? "").split(",").filter(Boolean),
      recent: rows(recent),
    },
  }
}
