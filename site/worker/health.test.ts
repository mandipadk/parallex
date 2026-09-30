import assert from "node:assert/strict"
import { test } from "node:test"
import { cohorts, judge, mondayOfWeek, type ReleaseCounts } from "./health.ts"

const none = { ok: 0, failed: 0, macsFailed: 0 }
const release = (over: Partial<ReleaseCounts>): ReleaseCounts => ({
  version: "1.6.0", macs: 40, crashedMacs: 0, hangs: 0,
  created: none, refreshed: none, updated: none, opened: none, leaks: none, ...over,
})

test("a quiet release with enough Macs is healthy", () => {
  const health = judge(release({ created: { ok: 30, failed: 0, macsFailed: 0 } }))
  assert.equal(health.verdict, "healthy")
  assert.equal(health.crashFree, 1)
})

test("too few Macs is early, unless something is clearly wrong", () => {
  assert.equal(judge(release({ macs: 3 })).verdict, "early")
  assert.equal(judge(release({ macs: 4, crashedMacs: 3 })).verdict, "failing")
})

test("crashes on several Macs fail a release", () => {
  const health = judge(release({ crashedMacs: 4 }))
  assert.equal(health.verdict, "failing")
  assert.match(health.reasons[0], /^Crash-free 90%/)
})

test("worse than the release before is worth watching", () => {
  const before = release({ version: "1.5.0", opened: { ok: 95, failed: 5, macsFailed: 1 } })
  const now = release({ opened: { ok: 80, failed: 20, macsFailed: 2 } })
  const health = judge(now, before)
  assert.equal(health.verdict, "watch")
  assert.ok(health.reasons.some((r) => r.includes("was 5.0%")))
})

test("updates failing on several Macs fail it", () => {
  assert.equal(judge(release({ updated: { ok: 6, failed: 4, macsFailed: 4 } })).verdict, "failing")
})

test("ISO weeks start on their Monday", () => {
  assert.equal(mondayOfWeek("2026-W40"), "2026-09-28")
  assert.equal(mondayOfWeek("2026-W01"), "2025-12-29")
  assert.equal(mondayOfWeek("2026-W53"), "2026-12-28")
  assert.equal(mondayOfWeek("nope"), null)
})

test("cohorts are shares of each week's newcomers, week by week", () => {
  const rows = [
    { cohort: "2026-W40", monday: "2026-09-28", installs: 10 },
    { cohort: "2026-W40", monday: "2026-10-05", installs: 6 },
    { cohort: "2026-W40", monday: "2026-10-19", installs: 4 },
    { cohort: "2026-W41", monday: "2026-10-05", installs: 5 },
  ]
  const result = cohorts(rows, { "2026-W40": 10, "2026-W41": 5 })
  assert.deepEqual(result.map((c) => c.cohort), ["2026-W41", "2026-W40"])
  assert.deepEqual(result[1].weeks, [1, 0.6, 0, 0.4])
  assert.deepEqual(result[0].weeks, [1])
})
