import type { IssueReport } from "./compatibility"
import type { Env } from "./env"
import { loadRollout, publishedReleases, versionOf, type Rollout } from "./feed"

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
  /** The newest few releases, newest first, and how the newest is going out. */
  published: string[]
  rollout: Rollout
  /** Opt-in usage: Macs that reported in the last 7 and 30 days. */
  usage: {
    macs7: number
    macs30: number
    apps: { name: string; bundle: string; macs: number; instances: number; failing: number; verified: number }[]
    warnings: { name: string; version: string; macs: number; failing: number }[]
    features: { name: string; macs: number }[]
  }
  /** GitHub compatibility reports, and which are on the public list. */
  reports: { issues: IssueReport[]; approved: number[] }
  /** Apps on the public list. */
  listed: string[]
  /** Today's active Macs by version (for adoption). */
  todayVersions: { name: string; count: number }[]
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

export async function summarize(env: Env, ctx: ExecutionContext, now = new Date()): Promise<Summary> {
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

  const [releases, rollout] = await Promise.all([publishedReleases(env, ctx), loadRollout(env)])
  const [issuesRow, approvedRows, listedRows] = await db.batch<Record<string, unknown>>([
    db.prepare(`SELECT body FROM feed WHERE key = 'compat-issues'`),
    db.prepare(`SELECT issue FROM approved_reports`),
    db.prepare(`SELECT bundle_id FROM listed_apps`),
  ])
  let issues: IssueReport[] = []
  try {
    issues = JSON.parse(String(issuesRow.results[0]?.body ?? "[]")) as IssueReport[]
  } catch {
    issues = []
  }
  const [usage7, usage30, usageApps, warnings, features] = await db.batch<Record<string, unknown>>([
    db.prepare(`SELECT COALESCE(SUM(macs), 0) AS n FROM usage_reports WHERE day >= ?1`).bind(since7),
    db.prepare(`SELECT COALESCE(SUM(macs), 0) AS n FROM usage_reports WHERE day >= ?1`).bind(since30),
    db.prepare(
      `SELECT MAX(name) AS name, bundle_id AS bundle, SUM(macs) AS macs, SUM(instances) AS instances,
              SUM(failing_macs) AS failing, SUM(verified_macs) AS verified
       FROM usage_apps WHERE day >= ?1 GROUP BY bundle_id ORDER BY macs DESC LIMIT 15`,
    ).bind(since30),
    // Early warnings: an app version whose copies quit at launch on two or
    // more Macs, and on at least a third of those that have it.
    db.prepare(
      `SELECT MAX(name) AS name, app_version AS version, SUM(macs) AS macs, SUM(failing_macs) AS failing
       FROM usage_apps WHERE day >= ?1 GROUP BY bundle_id, app_version
       HAVING SUM(failing_macs) >= 2 AND SUM(failing_macs) * 3 >= SUM(macs) ORDER BY failing DESC LIMIT 10`,
    ).bind(since7),
    db.prepare(`SELECT feature AS name, SUM(macs) AS macs FROM usage_features WHERE day >= ?1 GROUP BY feature ORDER BY macs DESC`)
      .bind(since30),
  ])
  const [day, week, month, fresh, installs, series, versions, os, arch, stats, kofi, recent, todayVersions] = await db.batch<Record<string, unknown>>([
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
    db.prepare(`SELECT version AS name, SUM(count) AS count FROM checks WHERE period = 'day' AND day = ?1 GROUP BY version ORDER BY count DESC`)
      .bind(today),
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
    published: releases.slice(0, 5).map(versionOf),
    rollout,
    todayVersions: rows(todayVersions),
    reports: { issues, approved: approvedRows.results.map((r) => Number(r.issue)) },
    listed: listedRows.results.map((r) => String(r.bundle_id)),
    usage: {
      macs7: n(usage7),
      macs30: n(usage30),
      apps: rows(usageApps),
      warnings: rows(warnings),
      features: rows(features),
    },
    donations: {
      kofiCents: Number(kofi.results[0]?.cents ?? 0),
      kofiCount: Number(kofi.results[0]?.n ?? 0),
      otherCurrencies: String(kofi.results[0]?.others ?? "").split(",").filter(Boolean),
      recent: rows(recent),
    },
  }
}
