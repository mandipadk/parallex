/**
 * Mission Control's judgments, worked out from counts: how healthy a release
 * is next to the one before, and which week a Mac's report falls in after
 * the week it started. Kept free of imports so it can be tested on its own.
 */

/** Successes and failures of something, counted in Macs and in times. */
export type Outcome = { ok: number; failed: number; macsFailed: number }

export type ReleaseCounts = {
  version: string
  /** Macs that reported from this version in the window. */
  macs: number
  /** Of those, how many had Parallex crash (hangs aren't counted here). */
  crashedMacs: number
  hangs: number
  created: Outcome
  refreshed: Outcome
  /** Updates to this version. */
  updated: Outcome
  /** Copies that ran, and that quit at launch. */
  opened: Outcome
  leaks: Outcome
}

export type Verdict = "early" | "healthy" | "watch" | "failing"

export type Health = {
  verdict: Verdict
  /** Why, in a few words each, worst first. */
  reasons: string[]
  crashFree: number | null
  rates: { created: number | null; refreshed: number | null; updated: number | null; opened: number | null; leaks: number | null }
}

/** Fewer Macs than this and a verdict would be noise. */
export const ENOUGH_MACS = 5

export const failureRate = (o: Outcome): number | null => (o.ok + o.failed > 0 ? o.failed / (o.ok + o.failed) : null)

const percent = (x: number) => `${(x * 100).toFixed(x < 0.1 ? 1 : 0)}%`

/**
 * A release's health on its own and next to the release before it. Failing:
 * a clear problem on several Macs. Watch: worse than before by a margin, or
 * a problem on a few. Healthy otherwise; early until enough Macs run it.
 */
export function judge(release: ReleaseCounts, previous?: ReleaseCounts): Health {
  const crashFree = release.macs > 0 ? 1 - release.crashedMacs / release.macs : null
  const rates = {
    created: failureRate(release.created),
    refreshed: failureRate(release.refreshed),
    updated: failureRate(release.updated),
    opened: failureRate(release.opened),
    leaks: failureRate(release.leaks),
  }
  const failing: string[] = []
  const watch: string[] = []
  if (crashFree !== null && release.crashedMacs >= 3 && crashFree < 0.97) failing.push(`Crash-free ${percent(crashFree)}`)
  else if (crashFree !== null && release.crashedMacs >= 1 && crashFree < 0.99) watch.push(`Crash-free ${percent(crashFree)}`)

  const checks: [keyof typeof rates, string, Outcome][] = [
    ["updated", "Updates to it failing", release.updated],
    ["created", "Instances not made", release.created],
    ["refreshed", "Refreshes failing", release.refreshed],
    ["opened", "Copies quitting at launch", release.opened],
    ["leaks", "Isolation checks finding leaks", release.leaks],
  ]
  for (const [key, label, outcome] of checks) {
    const rate = rates[key]
    if (rate === null || outcome.macsFailed === 0) continue
    const before = previous ? failureRate(previous[key]) : null
    const worse = before !== null && rate > before * 1.5 + 0.02
    if (outcome.macsFailed >= 3 && rate >= 0.2) failing.push(`${label}: ${percent(rate)}`)
    else if (worse || (outcome.macsFailed >= 2 && rate >= 0.1)) watch.push(`${label}: ${percent(rate)}${before !== null ? `, was ${percent(before)}` : ""}`)
  }
  if (release.hangs > 0 && previous && release.hangs > previous.hangs * 2 + 2) watch.push(`Hangs: ${release.hangs}, was ${previous.hangs}`)

  const verdict: Verdict = failing.length ? "failing" : release.macs < ENOUGH_MACS ? "early" : watch.length ? "watch" : "healthy"
  return { verdict, reasons: [...failing, ...watch], crashFree, rates }
}

/** Monday of an ISO week ("2026-W40"), as "2026-09-28"; null if it isn't one. */
export function mondayOfWeek(week: string): string | null {
  const match = /^(\d{4})-W(\d{2})$/.exec(week)
  if (!match) return null
  const year = Number(match[1])
  const number = Number(match[2])
  // January 4th is always in week 1.
  const jan4 = new Date(Date.UTC(year, 0, 4))
  const monday = new Date(jan4.getTime() - ((jan4.getUTCDay() + 6) % 7) * 86_400_000)
  return new Date(monday.getTime() + (number - 1) * 7 * 86_400_000).toISOString().slice(0, 10)
}

/** Whole weeks from one Monday to another. */
export const weeksBetween = (from: string, to: string): number =>
  Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / (7 * 86_400_000))

export type CohortRow = { cohort: string; monday: string; installs: number }
export type Cohort = { cohort: string; start: string; size: number; weeks: number[] }

/**
 * Cohorts from how many of each week's newcomers reported in each later
 * week: weeks[k] is the share still reporting k weeks on.
 */
export function cohorts(rows: CohortRow[], sizes: Record<string, number>, limit = 12): Cohort[] {
  const byCohort = new Map<string, Map<number, number>>()
  for (const row of rows) {
    const start = mondayOfWeek(row.cohort)
    if (!start) continue
    const week = weeksBetween(start, row.monday)
    if (week < 0 || week >= limit) continue
    const weeks = byCohort.get(row.cohort) ?? new Map<number, number>()
    weeks.set(week, (weeks.get(week) ?? 0) + row.installs)
    byCohort.set(row.cohort, weeks)
  }
  return [...byCohort.entries()]
    .map(([cohort, weeks]) => {
      const size = sizes[cohort] ?? 0
      const last = Math.max(...weeks.keys())
      return {
        cohort,
        start: mondayOfWeek(cohort) ?? "",
        size,
        weeks: Array.from({ length: last + 1 }, (_, k) => (size ? Math.min(1, (weeks.get(k) ?? 0) / size) : 0)),
      }
    })
    .sort((a, b) => b.start.localeCompare(a.start))
    .slice(0, limit)
}
