import assert from "node:assert/strict"
import { test } from "node:test"
import { decide, readGuardrails, type RolloutState } from "./guardrails.ts"

const on = readGuardrails({ enabled: true })
const now = new Date("2026-10-02T12:00:00Z")
const healthy = { verdict: "healthy" as const, reasons: [], macs: 40 }
const at = (percent: number, hoursAgo: number, extra: Partial<RolloutState> = {}): RolloutState => ({
  version: "1.7.0", percent, paused: false, pulled: [], startPercent: 10,
  changedAt: new Date(now.getTime() - hoursAgo * 3_600_000).toISOString(), ...extra,
})

test("off does nothing", () => {
  assert.equal(decide(readGuardrails({}), at(10, 99), "1.7.0", healthy, now).action, "hold")
})

test("a new release starts at the first step", () => {
  const decision = decide(on, at(100, 99, { version: "1.6.0" }), "1.7.0", healthy, now)
  assert.deepEqual(decision, { action: "adopt", version: "1.7.0", percent: 10, reason: "1.7.0 starts at 10%" })
})

test("a healthy release moves on once it has had its time and its Macs", () => {
  assert.equal((decide(on, at(10, 25), "1.7.0", healthy, now) as { percent: number }).percent, 50)
  assert.equal((decide(on, at(50, 25), "1.7.0", healthy, now) as { percent: number }).percent, 100)
  assert.equal(decide(on, at(10, 3), "1.7.0", healthy, now).action, "hold", "not yet a day")
  assert.equal(decide(on, at(10, 25), "1.7.0", { ...healthy, verdict: "early" }, now).action, "advance", "early, nothing wrong, enough Macs")
})

test("too few Macs: a step passes only after three quiet periods", () => {
  const few = { verdict: "early" as const, reasons: [], macs: 2 }
  assert.equal(decide(on, at(10, 25), "1.7.0", few, now).action, "hold")
  assert.equal(decide(on, at(10, 73), "1.7.0", few, now).action, "advance")
})

test("anything wrong holds it, even on too few Macs for a verdict", () => {
  const early = { verdict: "early" as const, reasons: ["Crash-free 75%"], macs: 4 }
  assert.equal(decide(on, at(10, 200), "1.7.0", early, now).action, "hold")
  assert.equal(decide(on, at(10, 48), "1.7.0", { verdict: "watch", reasons: ["x"], macs: 40 }, now).action, "hold")
})

test("failing pauses; by-hand choices stand", () => {
  const failing = { verdict: "failing" as const, reasons: ["Crash-free 90%"], macs: 40 }
  assert.equal(decide(on, at(10, 2), "1.7.0", failing, now).action, "pause")
  assert.equal(decide(on, at(100, 48), "1.7.0", failing, now).action, "pause", "even at everyone")
  assert.equal(decide(on, at(10, 48, { paused: true, pausedBy: "hand" }), "1.7.0", healthy, now).action, "hold")
  assert.equal(decide(on, at(10, 48, { pulled: ["1.7.0"] }), "1.7.0", healthy, now).action, "hold")
  const resumed = decide(on, at(10, 1, { resumedByHand: "1.7.0" }), "1.7.0", failing, now)
  assert.equal(resumed.action, "hold", "resumed by hand: not paused again for the same trouble, and not moved on")
})

test("stored settings are checked", () => {
  assert.deepEqual(readGuardrails({ enabled: true, steps: [50, 5, 5], hours: 0, minMacs: 2 }), {
    enabled: true, steps: [5, 50, 100], hours: 24, minMacs: 5, startBefore: undefined,
  })
  assert.equal(readGuardrails({ startBefore: 100 }).startBefore, 100)
})
