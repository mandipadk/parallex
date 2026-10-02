import assert from "node:assert/strict"
import { test } from "node:test"
import { historyLine } from "./page.ts"

test("an unbroken run of clean nights", () => {
  assert.equal(historyLine([
    { day: "2026-10-03", version: "1.2", result: "ran" },
    { day: "2026-10-02", version: "1.2", result: "not installed" },
    { day: "2026-10-01", version: "1.1", result: "ran" },
  ]), "Its copies have run clean on all 2 nights since October 1.")
})

test("trouble, then clean again", () => {
  assert.equal(historyLine([
    { day: "2026-10-03", version: "12.11", result: "ran" },
    { day: "2026-10-02", version: "12.10", result: "ran" },
    { day: "2026-10-01", version: "12.10", result: "quit" },
    { day: "2026-09-30", version: "12.9", result: "ran" },
  ]), "Its copies last had trouble on October 1 (12.10, quit at launch), and have run clean on the 2 nights since.")
})

test("a wrapper's nights are its instances', not its copies'", () => {
  assert.equal(historyLine([
    { day: "2026-10-02", version: "153", result: "ran" },
    { day: "2026-10-01", version: "153", result: "ran" },
  ], "wrapper"), "Its instances have run clean on all 2 nights since October 1.")
})

test("nothing to say with one night, or when it's failing now", () => {
  assert.equal(historyLine([{ day: "2026-10-01", version: "1", result: "ran" }]), "")
  assert.equal(historyLine([{ day: "2026-10-02", version: "1", result: "quit" }, { day: "2026-10-01", version: "1", result: "ran" }]), "")
  assert.equal(historyLine(undefined), "")
})
