import type { IssueReport } from "./compatibility"
import type { Env } from "./env"
import { loadRollout, publishedReleases, versionOf } from "./feed"
import { cohorts, judge, mondayOfWeek, type Outcome, type ReleaseCounts } from "./health"
import { isLater } from "./notes.ts"
import type { Alert, AppRow, Apps, Community, CrashGroup, Crashes, Growth, Named, Overview, ReleaseRow, Releases } from "./mission-types"

/**
 * Mission Control's API (/admin/api/…, signed in only): what the usage
 * reports and update checks add up to, per release, crash, app and week.
 * Counts are of Macs (install numbers), never of reports.
 */

type Row = Record<string, unknown>
const iso = (date: Date) => date.toISOString().slice(0, 10)
const daysAgo = (now: Date, days: number) => iso(new Date(now.getTime() - days * 86_400_000))
const num = (value: unknown) => Number(value ?? 0) || 0
const str = (value: unknown) => (value === null || value === undefined ? "" : String(value))

/** Monday of this week and the 1st of this month (UTC, like the counts). */
function periodStarts(now: Date): { week: string; month: string } {
  const monday = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
  monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7))
  return { week: iso(monday), month: iso(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1))) }
}

/** A window of days, from the query (7, 30 or 90; 30 otherwise). */
export function windowOf(request: Request): number {
  const days = Number(new URL(request.url).searchParams.get("days"))
  return [7, 14, 30, 90].includes(days) ? days : 30
}

// MARK: Releases

const empty = (): Outcome => ({ ok: 0, failed: 0, macsFailed: 0 })

/** What happened on each version since `since`. */
async function releaseCounts(env: Env, since: string): Promise<Map<string, ReleaseCounts>> {
  const db = env.DB
  const [macs, crashes, events, updates] = await db.batch<Row>([
    db.prepare(`SELECT version, COUNT(DISTINCT install) AS macs FROM install_days WHERE day >= ?1 GROUP BY version`).bind(since),
    db.prepare(`SELECT version, kind, COUNT(DISTINCT install) AS macs, SUM(n) AS total FROM crashes WHERE day >= ?1 GROUP BY version, kind`).bind(since),
    db.prepare(`SELECT version, name, json_extract(props, '$.result') AS result, SUM(n) AS total, COUNT(DISTINCT install) AS macs
      FROM events WHERE day >= ?1 AND name IN ('instance.created', 'copy.refreshed', 'instance.opened', 'isolation.checked')
      GROUP BY version, name, result`).bind(since),
    // An update is counted against the version it went to.
    db.prepare(`SELECT json_extract(props, '$.version') AS version, json_extract(props, '$.result') AS result, SUM(n) AS total,
      COUNT(DISTINCT install) AS macs FROM events WHERE day >= ?1 AND name = 'update.installed' GROUP BY 1, 2`).bind(since),
  ])
  const counts = new Map<string, ReleaseCounts>()
  const of = (version: string) => {
    let found = counts.get(version)
    if (!found) {
      found = {
        version, macs: 0, crashedMacs: 0, hangs: 0,
        created: empty(), refreshed: empty(), updated: empty(), opened: empty(), leaks: empty(),
      }
      counts.set(version, found)
    }
    return found
  }
  for (const row of macs.results) of(str(row.version)).macs = num(row.macs)
  for (const row of crashes.results) {
    const release = of(str(row.version))
    if (row.kind === "crash") release.crashedMacs = num(row.macs)
    else release.hangs = num(row.total)
  }
  const add = (outcome: Outcome, good: boolean, row: Row) => {
    if (good) outcome.ok += num(row.total)
    else {
      outcome.failed += num(row.total)
      outcome.macsFailed += num(row.macs)
    }
  }
  for (const row of events.results) {
    const release = of(str(row.version))
    const result = str(row.result)
    switch (row.name) {
      case "instance.created": if (result === "ok" || result === "failed") add(release.created, result === "ok", row); break
      case "copy.refreshed": if (result === "ok" || result === "failed") add(release.refreshed, result === "ok", row); break
      case "instance.opened": if (result === "ran" || result === "quit at launch") add(release.opened, result === "ran", row); break
      case "isolation.checked": if (result === "clean" || result === "leak") add(release.leaks, result === "clean", row); break
    }
  }
  for (const row of updates.results) {
    const result = str(row.result)
    if (result === "ok" || result === "failed") add(of(str(row.version)).updated, result === "ok", row)
  }
  return counts
}

const pair = (o: Outcome): [number, number] => [o.ok, o.failed]

function releaseRows(published: string[], counts: Map<string, ReleaseCounts>, checksToday: Map<string, number>): ReleaseRow[] {
  // Newest first: the newest release, and any with reports in the window.
  const known = [...new Set([...published.slice(0, 1), ...[...counts.keys()].filter((v) => v !== "other" && /^\d/.test(v))])]
    .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))
  return known.slice(0, 10).map((version, index) => {
    const release = counts.get(version) ?? {
      version, macs: 0, crashedMacs: 0, hangs: 0, created: empty(), refreshed: empty(), updated: empty(), opened: empty(), leaks: empty(),
    }
    const previous = counts.get(known[index + 1] ?? "")
    return {
      version,
      published: published.includes(version),
      macs: release.macs,
      checksToday: checksToday.get(version) ?? 0,
      health: judge(release, previous),
      counts: {
        created: pair(release.created), refreshed: pair(release.refreshed), updated: pair(release.updated),
        opened: pair(release.opened), leaks: pair(release.leaks),
        hangs: release.hangs, crashedMacs: release.crashedMacs,
      },
    }
  })
}

export async function releases(env: Env, ctx: ExecutionContext, days: number, now = new Date()): Promise<Releases> {
  const since = daysAgo(now, days - 1)
  const db = env.DB
  const [published, rollout, counts] = await Promise.all([
    publishedReleases(env, ctx).then((list) => list.map(versionOf)),
    loadRollout(env),
    releaseCounts(env, since),
  ])
  const [today, adoption, stats, steps, osToday] = await db.batch<Row>([
    db.prepare(`SELECT version, SUM(count) AS n FROM checks WHERE period = 'day' AND day = ?1 GROUP BY version`).bind(iso(now)),
    db.prepare(`SELECT day, version, SUM(count) AS n FROM checks WHERE period = 'day' AND day >= ?1 GROUP BY day, version ORDER BY day`).bind(since),
    db.prepare(`SELECT key, value FROM stats s WHERE key LIKE 'downloads:%' AND day = (SELECT MAX(day) FROM stats WHERE key = s.key)`),
    db.prepare(`SELECT json_extract(props, '$.step') AS name, SUM(n) AS count FROM events
      WHERE day >= ?1 AND name = 'update.installed' AND json_extract(props, '$.result') = 'failed' GROUP BY 1 ORDER BY count DESC`).bind(since),
    db.prepare(`SELECT substr(os, 1, instr(os || '.', '.') - 1) AS name, SUM(count) AS count FROM checks
      WHERE period = 'day' AND day >= ?1 AND os <> 'other' GROUP BY 1 ORDER BY name DESC`).bind(daysAgo(now, 6)),
  ])
  const checksToday = new Map(today.results.map((r) => [str(r.version), num(r.n)]))
  const byDay = new Map<string, Record<string, number>>()
  for (const row of adoption.results) {
    const versions = byDay.get(str(row.day)) ?? {}
    versions[str(row.version)] = num(row.n)
    byDay.set(str(row.day), versions)
  }
  return {
    rollout: {
      version: rollout.version ?? "", percent: rollout.percent, paused: rollout.paused, pulled: rollout.pulled,
      startPercent: rollout.startPercent, heldOS: rollout.heldOS ?? [],
    },
    osToday: osToday.results.map((r) => ({ name: str(r.name), count: num(r.count) })),
    published: published.slice(0, 10),
    releases: releaseRows(published, counts, checksToday),
    adoption: Array.from({ length: days }, (_, i) => daysAgo(now, days - 1 - i)).map((day) => ({ day, versions: byDay.get(day) ?? {} })),
    downloads: stats.results
      .map((r) => ({ tag: str(r.key).slice("downloads:".length), downloads: num(r.value) }))
      .sort((a, b) => b.tag.localeCompare(a.tag, undefined, { numeric: true }))
      .slice(0, 10),
    updateSteps: steps.results.map((r) => ({ name: str(r.name) || "other", count: num(r.count) })),
  }
}

// MARK: Crashes

export async function crashes(env: Env, days: number, now = new Date()): Promise<Crashes> {
  const since = daysAgo(now, days - 1)
  const db = env.DB
  const [groups, versions, daily, free] = await db.batch<Row>([
    db.prepare(`SELECT c.signature, s.kind, s.summary, s.frames, s.first_day, s.last_day, s.first_version, s.last_version,
        COUNT(DISTINCT c.install) AS macs, SUM(c.n) AS total
      FROM crashes c JOIN crash_signatures s ON s.signature = c.signature WHERE c.day >= ?1
      GROUP BY c.signature ORDER BY macs DESC, total DESC LIMIT 50`).bind(since),
    db.prepare(`SELECT signature, version, SUM(n) AS n FROM crashes WHERE day >= ?1 GROUP BY signature, version`).bind(since),
    db.prepare(`SELECT signature, day, SUM(n) AS n FROM crashes WHERE day >= ?1 GROUP BY signature, day`).bind(since),
    db.prepare(`SELECT d.version, COUNT(DISTINCT d.install) AS macs,
        COUNT(DISTINCT CASE WHEN c.install IS NOT NULL THEN d.install END) AS crashed
      FROM install_days d LEFT JOIN crashes c ON c.install = d.install AND c.version = d.version AND c.day >= ?1 AND c.kind = 'crash'
      WHERE d.day >= ?1 GROUP BY d.version ORDER BY d.version DESC`).bind(since),
  ])
  const window = Array.from({ length: days }, (_, i) => daysAgo(now, days - 1 - i))
  const index = new Map(window.map((day, i) => [day, i]))
  const perVersion = new Map<string, Named[]>()
  for (const row of versions.results) {
    const list = perVersion.get(str(row.signature)) ?? []
    list.push({ name: str(row.version), count: num(row.n) })
    perVersion.set(str(row.signature), list)
  }
  const perDay = new Map<string, number[]>()
  for (const row of daily.results) {
    const series = perDay.get(str(row.signature)) ?? new Array<number>(days).fill(0)
    const at = index.get(str(row.day))
    if (at !== undefined) series[at] += num(row.n)
    perDay.set(str(row.signature), series)
  }
  return {
    days: window,
    groups: groups.results.map((row): CrashGroup => {
      let frames: CrashGroup["frames"] = []
      try {
        frames = JSON.parse(str(row.frames)) as CrashGroup["frames"]
      } catch {
        frames = []
      }
      const signature = str(row.signature)
      return {
        signature, kind: row.kind === "hang" ? "hang" : "crash", summary: str(row.summary), frames,
        firstDay: str(row.first_day), lastDay: str(row.last_day), firstVersion: str(row.first_version), lastVersion: str(row.last_version),
        macs: num(row.macs), total: num(row.total),
        versions: (perVersion.get(signature) ?? []).sort((a, b) => b.name.localeCompare(a.name, undefined, { numeric: true })),
        days: perDay.get(signature) ?? new Array<number>(days).fill(0),
      }
    }),
    crashFree: free.results
      .map((r) => ({ version: str(r.version), macs: num(r.macs), crashed: num(r.crashed) }))
      .sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true })),
  }
}

// MARK: Apps

/** Each Mac's latest gauges in the last week (a report replaces its day's). */
const latestGauges = (name: string) => `SELECT g.* FROM gauges g
  WHERE g.name = '${name}' AND g.day >= ?1 AND g.day = (SELECT MAX(day) FROM gauges WHERE install = g.install AND day >= ?1)`

export async function apps(env: Env, days: number, now = new Date()): Promise<Apps> {
  const since = daysAgo(now, days - 1)
  const week = daysAgo(now, 6)
  const db = env.DB
  const [have, events, other, websites, otherWebsites, frameworks, steps, listed, names] = await db.batch<Row>([
    db.prepare(`SELECT json_extract(props, '$.app') AS app, json_extract(props, '$.version') AS version, json_extract(props, '$.kind') AS kind,
      MAX(json_extract(props, '$.name')) AS name, COUNT(DISTINCT install) AS macs, SUM(value) AS instances
      FROM (${latestGauges("app")}) GROUP BY 1, 2, 3`).bind(week),
    db.prepare(`SELECT json_extract(props, '$.app') AS app, json_extract(props, '$.version') AS version, name,
        json_extract(props, '$.result') AS result, SUM(n) AS total, COUNT(DISTINCT install) AS macs
      FROM events WHERE day >= ?1 AND name IN ('instance.opened', 'copy.refreshed', 'isolation.checked', 'instance.created')
      GROUP BY 1, 2, 3, 4`).bind(since),
    db.prepare(`SELECT COUNT(DISTINCT install) AS macs, SUM(value) AS apps FROM (${latestGauges("app.other")})`).bind(week),
    db.prepare(`SELECT json_extract(props, '$.app') AS name, COUNT(DISTINCT install) AS count FROM (${latestGauges("website")})
      GROUP BY 1 ORDER BY count DESC`).bind(week),
    db.prepare(`SELECT SUM(value) AS n FROM (${latestGauges("website.other")})`).bind(week),
    db.prepare(`SELECT json_extract(props, '$.framework') AS framework, json_extract(props, '$.result') AS result, SUM(n) AS n
      FROM events WHERE day >= ?1 AND name = 'instance.created' GROUP BY 1, 2`).bind(since),
    db.prepare(`SELECT json_extract(props, '$.step') AS name, SUM(n) AS count FROM events
      WHERE day >= ?1 AND name = 'instance.created' AND json_extract(props, '$.result') = 'failed' GROUP BY 1 ORDER BY count DESC`).bind(since),
    db.prepare(`SELECT bundle_id, name FROM listed_apps`),
    db.prepare(`SELECT bundle_id, MAX(name) AS name FROM usage_apps GROUP BY bundle_id`),
  ])
  const nameOf = new Map<string, string>()
  for (const row of names.results) nameOf.set(str(row.bundle_id), str(row.name))
  const listedIDs = new Set<string>()
  for (const row of listed.results) {
    listedIDs.add(str(row.bundle_id))
    nameOf.set(str(row.bundle_id), str(row.name))
  }
  const rows = new Map<string, AppRow>()
  const of = (app: string): AppRow => {
    let row = rows.get(app)
    if (!row) {
      row = {
        app, name: nameOf.get(app) ?? null, listed: listedIDs.has(app), macs: 0, instances: 0, kinds: [], versions: [],
        ran: 0, quit: 0, created: [0, 0], refreshed: [0, 0], leaks: [0, 0], flagged: false, flaggedVersions: [],
      }
      rows.set(app, row)
    }
    return row
  }
  const versionOfRow = (row: AppRow, version: string) => {
    let found = row.versions.find((v) => v.version === version)
    if (!found) {
      found = { version, macs: 0, ran: 0, quit: 0, refreshFailed: 0, leaks: 0 }
      row.versions.push(found)
    }
    return found
  }
  // Macs are counted per app across versions and kinds by the largest
  // group, since one Mac can have several (an undercount, never an over).
  for (const r of have.results) {
    const row = of(str(r.app))
    row.name ??= r.name ? str(r.name) : null
    row.instances += num(r.instances)
    const kind = row.kinds.find((k) => k.name === str(r.kind))
    if (kind) kind.count += num(r.instances)
    else row.kinds.push({ name: str(r.kind), count: num(r.instances) })
    const version = versionOfRow(row, str(r.version))
    version.macs += num(r.macs)
    row.macs = Math.max(row.macs, version.macs)
  }
  // Macs where copies of each app version quit at launch.
  const quitMacs = new Map<string, number>()
  for (const r of events.results) {
    const app = str(r.app)
    if (!app || app === "other") continue
    const row = of(app)
    const result = str(r.result)
    const total = num(r.total)
    const version = r.version ? versionOfRow(row, str(r.version)) : null
    switch (r.name) {
      case "instance.opened":
        if (result === "ran") {
          row.ran += total
          if (version) version.ran += total
        } else if (result === "quit at launch") {
          row.quit += total
          quitMacs.set(`${app} ${str(r.version)}`, (quitMacs.get(`${app} ${str(r.version)}`) ?? 0) + num(r.macs))
          if (version) version.quit += total
        }
        break
      case "instance.created":
        if (result === "ok") row.created[0] += total
        else if (result === "failed") row.created[1] += total
        break
      case "copy.refreshed":
        if (result === "ok") row.refreshed[0] += total
        else if (result === "failed") {
          row.refreshed[1] += total
          if (version) version.refreshFailed += total
        }
        break
      case "isolation.checked":
        if (result === "clean") row.leaks[0] += total
        else if (result === "leak") {
          row.leaks[1] += total
          if (version) version.leaks += total
        }
        break
    }
  }
  for (const row of rows.values()) {
    // Flagged when one version's copies quit at launch on two or more
    // Macs, and on a third of its starts (a new version breaking copies
    // shouldn't hide behind the older ones that work).
    const failing = row.versions.filter((v) => (quitMacs.get(`${row.app} ${v.version}`) ?? 0) >= 2 && v.quit * 3 >= v.ran + v.quit)
    row.flagged = failing.length > 0 || ((quitMacs.get(`${row.app} `) ?? 0) >= 2 && row.quit * 3 >= row.ran + row.quit)
    row.flaggedVersions = failing.map((v) => v.version)
    row.versions.sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))
    row.kinds.sort((a, b) => b.count - a.count)
  }
  const byFramework = new Map<string, { framework: string; ok: number; failed: number }>()
  for (const r of frameworks.results) {
    const framework = str(r.framework) || "unknown"
    const entry = byFramework.get(framework) ?? { framework, ok: 0, failed: 0 }
    if (r.result === "ok") entry.ok += num(r.n)
    else if (r.result === "failed") entry.failed += num(r.n)
    byFramework.set(framework, entry)
  }
  return {
    apps: [...rows.values()].filter((r) => r.app !== "other").sort((a, b) => Number(b.flagged) - Number(a.flagged) || b.macs - a.macs || b.ran - a.ran),
    other: { macs: num(other.results[0]?.macs), apps: num(other.results[0]?.apps) },
    websites: websites.results.map((r) => ({ name: str(r.name), count: num(r.count) })),
    otherWebsites: num(otherWebsites.results[0]?.n),
    frameworks: [...byFramework.values()].sort((a, b) => b.ok + b.failed - (a.ok + a.failed)),
    createSteps: steps.results.map((r) => ({ name: str(r.name) || "other", count: num(r.count) })),
  }
}

// MARK: Growth

const FUNNEL_LABELS: Record<string, string> = {
  welcome: "Opened Parallex", "first-instance": "Picked a first app", privacy: "Reached the last step", done: "Finished setup",
}

export async function growth(env: Env, days: number, now = new Date()): Promise<Growth> {
  const since = daysAgo(now, days - 1)
  const week = daysAgo(now, 6)
  const db = env.DB
  // Each step is of the Macs that made the one before.
  const newInstalls = `SELECT install FROM installs WHERE first_day >= ?1 AND renewed = 0`
  const madeOne = `SELECT install FROM events WHERE name = 'instance.created' AND json_extract(props, '$.result') = 'ok'
    AND install IN (${newInstalls})`
  const ranOne = `SELECT install FROM events WHERE name = 'instance.opened' AND json_extract(props, '$.result') = 'ran'
    AND install IN (${madeOne})`
  const [installed, fresh, reporting, created, ran, returned, onboarding, weekly, sizes, first, features, sharing, commands, os, arch, version, sources] =
    await db.batch<Row>([
      db.prepare(`SELECT COALESCE(SUM(count), 0) AS n FROM checks WHERE period = 'install' AND day >= ?1`).bind(since),
      db.prepare(`SELECT COALESCE(SUM(count), 0) AS n FROM checks WHERE period = 'new' AND day >= ?1`).bind(since),
      db.prepare(`SELECT COUNT(*) AS n FROM installs WHERE first_day >= ?1 AND renewed = 0`).bind(since),
      db.prepare(`SELECT COUNT(DISTINCT install) AS n FROM (${madeOne})`).bind(since),
      db.prepare(`SELECT COUNT(DISTINCT install) AS n FROM (${ranOne})`).bind(since),
      // Still reporting a week or more after their first report.
      db.prepare(`SELECT COUNT(*) AS n FROM installs WHERE first_day >= ?1 AND renewed = 0 AND julianday(last_day) - julianday(first_day) >= 7
        AND install IN (${ranOne})`).bind(since),
      db.prepare(`SELECT json_extract(props, '$.step') AS name, COUNT(DISTINCT install) AS count FROM events
        WHERE name = 'onboarding.step' AND day >= ?1 GROUP BY 1`).bind(since),
      db.prepare(`SELECT i.cohort, date(d.day, 'weekday 0', '-6 days') AS monday, COUNT(DISTINCT d.install) AS installs
        FROM install_days d JOIN installs i ON i.install = d.install GROUP BY 1, 2`),
      db.prepare(`SELECT cohort, COUNT(*) AS n FROM installs WHERE renewed = 0 GROUP BY cohort`),
      db.prepare(`SELECT MIN(day) AS day FROM install_days`),
      db.prepare(`SELECT json_extract(props, '$.feature') AS name, COUNT(DISTINCT install) AS count FROM (${latestGauges("feature")})
        GROUP BY 1 ORDER BY count DESC`).bind(week),
      db.prepare(`SELECT COUNT(DISTINCT install) AS n FROM install_days WHERE day >= ?1`).bind(week),
      db.prepare(`SELECT json_extract(props, '$.command') AS name, SUM(n) AS count FROM events WHERE name = 'cli.command' AND day >= ?1
        GROUP BY 1 ORDER BY count DESC`).bind(since),
      db.prepare(`SELECT os AS name, COUNT(*) AS count FROM installs WHERE last_day >= ?1 GROUP BY os ORDER BY count DESC`).bind(since),
      db.prepare(`SELECT arch AS name, COUNT(*) AS count FROM installs WHERE last_day >= ?1 GROUP BY arch ORDER BY count DESC`).bind(since),
      db.prepare(`SELECT version AS name, COUNT(*) AS count FROM installs WHERE last_day >= ?1 GROUP BY version ORDER BY count DESC`).bind(since),
      db.prepare(`SELECT json_extract(props, '$.source') AS name, SUM(n) AS count FROM events WHERE name = 'instance.created'
        AND json_extract(props, '$.result') = 'ok' AND day >= ?1 GROUP BY 1 ORDER BY count DESC`).bind(since),
    ])
  const n = (result: D1Result<Row>) => num(result.results[0]?.n)
  const named = (result: D1Result<Row>): Named[] => result.results.map((r) => ({ name: str(r.name) || "other", count: num(r.count) }))
  // Weeks before reports began can't count as missed.
  const started = str(first.results[0]?.day)
  const startedMonday = started ? periodStarts(new Date(`${started}T00:00:00Z`)).week : ""
  const sizeOf = Object.fromEntries(sizes.results.map((r) => [str(r.cohort), num(r.n)]))
  const rows = weekly.results
    .map((r) => ({ cohort: str(r.cohort), monday: str(r.monday), installs: num(r.installs) }))
    .filter((r) => (mondayOfWeek(r.cohort) ?? "") >= startedMonday)
  const sharingMacs = n(sharing)
  const steps = named(onboarding)
  return {
    funnel: [
      { step: "installed", label: "Installed from Terminal", macs: n(installed) },
      { step: "new", label: "New Macs checking for updates", macs: n(fresh) },
      { step: "reporting", label: "New Macs sharing usage", macs: n(reporting) },
      { step: "created", label: "Made an instance", macs: n(created) },
      { step: "ran", label: "Ran a copy", macs: n(ran) },
      { step: "returned", label: "Still here a week on", macs: n(returned) },
    ],
    onboarding: ["welcome", "first-instance", "privacy", "done"].map((step) => ({
      name: FUNNEL_LABELS[step], count: steps.find((s) => s.name === step)?.count ?? 0,
    })),
    cohorts: cohorts(rows, sizeOf),
    features: named(features).map((f) => ({ feature: f.name, macs: f.count, share: sharingMacs ? f.count / sharingMacs : 0 })),
    commands: named(commands),
    platforms: { os: named(os), arch: named(arch), version: named(version) },
    sources: named(sources),
  }
}

// MARK: Overview

export async function overview(env: Env, ctx: ExecutionContext, days: number, now = new Date()): Promise<Overview> {
  const today = iso(now)
  const since = daysAgo(now, days - 1)
  const week = daysAgo(now, 6)
  const starts = periodStarts(now)
  const db = env.DB
  const sum = (period: string, from: string) =>
    db.prepare(`SELECT COALESCE(SUM(count), 0) AS n FROM checks WHERE period = ?1 AND day >= ?2`).bind(period, from)
  const sharingSince = (from: string) => db.prepare(`SELECT COUNT(DISTINCT install) AS n FROM install_days WHERE day >= ?1`).bind(from)
  const [day, weekly, monthly, fresh, sDay, sWeek, sMonth, sNew, series, sharingSeries, crashSeries, kinds, made, snapshots] = await db.batch<Row>([
    sum("day", today), sum("week", starts.week), sum("month", starts.month), sum("new", week),
    sharingSince(today), sharingSince(week), sharingSince(daysAgo(now, 29)),
    db.prepare(`SELECT COUNT(*) AS n FROM installs WHERE first_day >= ?1 AND renewed = 0`).bind(week),
    db.prepare(`SELECT day, SUM(CASE WHEN period = 'day' THEN count ELSE 0 END) AS active,
      SUM(CASE WHEN period = 'new' THEN count ELSE 0 END) AS fresh FROM checks WHERE day >= ?1 GROUP BY day`).bind(since),
    db.prepare(`SELECT day, COUNT(*) AS n FROM install_days WHERE day >= ?1 GROUP BY day`).bind(since),
    db.prepare(`SELECT day, SUM(n) AS n FROM crashes WHERE day >= ?1 AND kind = 'crash' GROUP BY day`).bind(since),
    db.prepare(`SELECT json_extract(props, '$.kind') AS kind, SUM(value) AS n FROM (${latestGauges("instances")}) GROUP BY 1`).bind(week),
    db.prepare(`SELECT COALESCE(SUM(n), 0) AS n FROM events WHERE name = 'instance.created' AND json_extract(props, '$.result') = 'ok' AND day >= ?1`).bind(since),
    db.prepare(`SELECT COALESCE(SUM(n), 0) AS n FROM events WHERE name = 'snapshot.taken' AND day >= ?1`).bind(since),
  ])
  // Each Mac once, from the number checks carry from 1.7 on; Macs on older
  // versions only have the check's own "first this month".
  const macsSince = (from: string) => db.prepare(`SELECT COUNT(DISTINCT mac) AS n FROM mac_days WHERE day >= ?1`).bind(from)
  const [mDay, mWeek, mMonth, mQuarter, mEver, mNew, mSeries, olderMonth] = await db.batch<Row>([
    macsSince(today), macsSince(week), macsSince(daysAgo(now, 29)), macsSince(daysAgo(now, 89)),
    db.prepare(`SELECT CAST(value AS INTEGER) AS n FROM settings WHERE key = 'macs_ever'`),
    db.prepare(`SELECT COUNT(*) AS n FROM macs WHERE first_day >= ?1 AND fresh = 1`).bind(week),
    db.prepare(`SELECT day, COUNT(*) AS n FROM mac_days WHERE day >= ?1 GROUP BY day`).bind(since),
    db.prepare(`SELECT version, SUM(count) AS n FROM checks WHERE period = 'month' AND day >= ?1 GROUP BY version`).bind(starts.month),
  ])
  const n = (result: D1Result<Row>) => num(result.results[0]?.n)
  const macsByDay = new Map(mSeries.results.map((r) => [str(r.day), num(r.n)]))
  const older = olderMonth.results
    .filter((r) => !/^\d+\.\d+/.test(str(r.version)) || !isLater(str(r.version), "1.6.999"))
    .reduce((total, r) => total + num(r.n), 0)
  const byDay = (result: D1Result<Row>, key = "n") => new Map(result.results.map((r) => [str(r.day), num(r[key])]))
  const [activeByDay, freshByDay, sharingByDay, crashesByDay] = [byDay(series, "active"), byDay(series, "fresh"), byDay(sharingSeries), byDay(crashSeries)]

  const [released, crashData, appData] = await Promise.all([releases(env, ctx, 7, now), crashes(env, 7, now), apps(env, 7, now)])
  const latestRow = released.releases.find((r) => r.published) ?? null
  const checksToday = released.releases.reduce((total, r) => total + r.checksToday, 0) || n(day)
  const alerts: Alert[] = []
  for (const release of released.releases.slice(0, 3)) {
    if (release.health.verdict === "failing" || release.health.verdict === "watch") {
      alerts.push({
        level: release.health.verdict, tab: "releases",
        title: `${release.version} is ${release.health.verdict === "failing" ? "failing" : "worth watching"}`,
        detail: release.health.reasons.slice(0, 2).join("; "),
      })
    }
  }
  for (const group of crashData.groups.filter((g) => g.firstDay >= daysAgo(now, 2) && g.macs >= 2).slice(0, 3)) {
    alerts.push({ level: "watch", tab: "crashes", title: `New ${group.kind}: ${group.summary}`, detail: `${group.macs} Macs since ${group.firstDay}, first in ${group.firstVersion}` })
  }
  for (const app of appData.apps.filter((a) => a.flagged).slice(0, 3)) {
    alerts.push({
      level: "watch", tab: "apps",
      title: `Copies of ${app.name ?? app.app}${app.flaggedVersions.length ? ` ${app.flaggedVersions.join(", ")}` : ""} quitting at launch`,
      detail: `${app.quit} of ${app.ran + app.quit} starts this week, across versions`,
    })
  }
  const kindCount = (kind: string) => num(kinds.results.find((r) => r.kind === kind)?.n)
  return {
    generated: now.toISOString(),
    active: { day: n(day), week: n(weekly), month: n(monthly) },
    newThisWeek: n(fresh),
    macs: { day: n(mDay), week: n(mWeek), month: n(mMonth), quarter: n(mQuarter), ever: n(mEver), newThisWeek: n(mNew), olderThisMonth: older },
    sharing: { day: n(sDay), week: n(sWeek), month: n(sMonth), newThisWeek: n(sNew) },
    series: Array.from({ length: days }, (_, i) => daysAgo(now, days - 1 - i)).map((d) => ({
      day: d, active: activeByDay.get(d) ?? 0, macs: macsByDay.get(d) ?? 0, fresh: freshByDay.get(d) ?? 0,
      sharing: sharingByDay.get(d) ?? 0, crashes: crashesByDay.get(d) ?? 0,
    })),
    latest: latestRow
      ? { version: latestRow.version, health: latestRow.health, macs: latestRow.macs, adoption: checksToday ? latestRow.checksToday / checksToday : 0 }
      : null,
    alerts,
    totals: {
      instances: kinds.results.reduce((total, r) => total + num(r.n), 0),
      copies: kindCount("copy") + kindCount("sandboxed copy"),
      web: kindCount("web"),
      created: n(made),
      snapshots: n(snapshots),
    },
  }
}

// MARK: Community

export async function community(env: Env): Promise<Community> {
  const db = env.DB
  const [issuesRow, approved, listed, stats, kofi, recent, log] = await db.batch<Row>([
    db.prepare(`SELECT body FROM feed WHERE key = 'compat-issues'`),
    db.prepare(`SELECT issue FROM approved_reports`),
    db.prepare(`SELECT bundle_id, name FROM listed_apps ORDER BY name`),
    db.prepare(`SELECT key, value FROM stats s WHERE day = (SELECT MAX(day) FROM stats WHERE key = s.key)`),
    db.prepare(`SELECT COALESCE(SUM(CASE WHEN currency = 'USD' THEN amount_cents ELSE 0 END), 0) AS cents, COUNT(*) AS n,
        GROUP_CONCAT(DISTINCT CASE WHEN currency <> 'USD' THEN currency END) AS others FROM donations WHERE at >= ?1`)
      .bind(daysAgo(new Date(), 365)),
    db.prepare(`SELECT kind, amount_cents AS cents, currency, at FROM donations ORDER BY at DESC LIMIT 8`),
    db.prepare(`SELECT at, action, detail FROM admin_log ORDER BY at DESC LIMIT 40`),
  ])
  let issues: IssueReport[] = []
  try {
    issues = JSON.parse(str(issuesRow.results[0]?.body) || "[]") as IssueReport[]
  } catch {
    issues = []
  }
  const approvedIssues = new Set(approved.results.map((r) => num(r.issue)))
  return {
    reports: issues.map((r) => ({ ...r, approved: approvedIssues.has(r.issue) })),
    listed: listed.results.map((r) => ({ bundle: str(r.bundle_id), name: str(r.name) })),
    stats: Object.fromEntries(stats.results.filter((r) => !str(r.key).startsWith("downloads:")).map((r) => [str(r.key), num(r.value)])),
    donations: {
      kofiCents: num(kofi.results[0]?.cents),
      kofiCount: num(kofi.results[0]?.n),
      otherCurrencies: str(kofi.results[0]?.others).split(",").filter(Boolean),
      recent: recent.results.map((r) => ({ kind: str(r.kind), cents: num(r.cents), currency: str(r.currency), at: str(r.at) })),
    },
    log: log.results.map((r) => ({ at: str(r.at), action: str(r.action), detail: str(r.detail) })),
  }
}

/** Keep a line of what was done from Mission Control. */
export async function logAction(env: Env, action: string, detail: string): Promise<void> {
  await env.DB.prepare(`INSERT INTO admin_log (at, action, detail) VALUES (?1, ?2, ?3)`)
    .bind(new Date().toISOString(), action.slice(0, 40), detail.slice(0, 200)).run()
}

// MARK: Export

const EXPORTS: Record<string, string> = {
  releases: `SELECT version, day, COUNT(*) AS macs FROM install_days GROUP BY version, day ORDER BY day, version`,
  events: `SELECT day, version, name, props, COUNT(DISTINCT install) AS macs, SUM(n) AS total FROM events GROUP BY day, version, name, props ORDER BY day`,
  crashes: `SELECT c.day, c.version, c.signature, s.summary, COUNT(DISTINCT c.install) AS macs, SUM(c.n) AS total
    FROM crashes c JOIN crash_signatures s ON s.signature = c.signature GROUP BY c.day, c.version, c.signature ORDER BY c.day`,
  checks: `SELECT day, period, version, os, arch, SUM(count) AS count FROM checks GROUP BY day, period, version, os, arch ORDER BY day`,
}

/** A table as CSV, added up per day (never install numbers). */
export async function exportCSV(env: Env, table: string): Promise<Response> {
  const query = Object.hasOwn(EXPORTS, table) ? EXPORTS[table] : undefined
  if (!query) return new Response("Not found", { status: 404 })
  const { results } = await env.DB.prepare(query).all<Row>()
  const columns = Object.keys(results[0] ?? {})
  const cell = (value: unknown) => {
    const text = str(value)
    return /[",\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text
  }
  const body = [columns.join(","), ...results.map((row) => columns.map((c) => cell(row[c])).join(","))].join("\n")
  return new Response(body, {
    headers: {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": `attachment; filename="parallex-${table}-${iso(new Date())}.csv"`,
      "Cache-Control": "no-store",
    },
  })
}
