import assert from "node:assert/strict"
import { test } from "node:test"
import { parseLab } from "./lab.ts"

test("reads a run, keeping only what the page shows", () => {
  const run = parseLab({
    date: "2026-09-30T07:50:00Z", macos: "26.1", parallex: "8ec23dd", extra: "ignored",
    apps: [
      { app: "Obsidian", version: "1.13.7", result: "ran", processes: 4, leaks: 0, blocked: 0, crashes: 0 },
      { app: "", result: "ran" },
      { app: "Broken", result: 7 },
      { app: "Zed", result: "quit", processes: -1 },
    ],
  })
  assert.ok(run)
  assert.deepEqual(run.apps.map((a) => a.app), ["Obsidian", "Zed"])
  assert.equal(run.apps[1].processes, undefined)
})

test("anything else is nothing", () => {
  assert.equal(parseLab(null), null)
  assert.equal(parseLab({ date: 5, apps: [] }), null)
  assert.equal(parseLab({ date: "x", apps: "no" }), null)
})
