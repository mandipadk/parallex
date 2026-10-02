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

test("reads how each instance was made, and a wrapper's own-identity copy", () => {
  const run = parseLab({
    date: "2026-10-03T07:50:00Z", macos: "26.1", parallex: "8ec23dd",
    apps: [
      { app: "Google Chrome", version: "153", mode: "wrapper", result: "ran", processes: 7, leaks: 0,
        ownIdentity: { result: "quit", processes: 0, leaks: 0, crashes: 0, extra: "ignored" } },
      { app: "Slack", version: "4.53", mode: "copy", result: "ran" },
      { app: "Old", result: "ran" },
      { app: "Odd", mode: "sideways", result: "ran", ownIdentity: { result: 5 } },
    ],
  })
  assert.ok(run)
  assert.equal(run.apps[0].mode, "wrapper")
  assert.deepEqual(run.apps[0].ownIdentity, { result: "quit", processes: 0, leaks: 0, blocked: undefined, crashes: 0 })
  assert.equal(run.apps[1].mode, "copy")
  assert.equal(run.apps[1].ownIdentity, undefined)
  assert.equal(run.apps[2].mode, undefined, "older runs say nothing: copies")
  assert.equal(run.apps[3].mode, undefined)
  assert.equal(run.apps[3].ownIdentity, undefined)
})

test("anything else is nothing", () => {
  assert.equal(parseLab(null), null)
  assert.equal(parseLab({ date: 5, apps: [] }), null)
  assert.equal(parseLab({ date: "x", apps: "no" }), null)
})
