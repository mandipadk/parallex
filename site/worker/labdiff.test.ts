import assert from "node:assert/strict"
import { test } from "node:test"
import { labChanges, noticeText } from "./labdiff.ts"

test("an app that stops running, or recovers, is a change; the rest isn't", () => {
  const previous = {
    Telegram: { version: "12.9", result: "ran" },
    Slack: { version: "4.52", result: "quit" },
    Zed: { version: "1.18", result: "ran" },
    Arc: { version: "1.1", result: "ran" },
  }
  const changes = labChanges(previous, [
    { app: "Telegram", version: "12.10", result: "crashed" },
    { app: "Slack", version: "4.53", result: "ran" },
    { app: "Zed", version: "1.18", result: "ran" },
    { app: "Arc", version: "1.2", result: "not installed" },
    { app: "Newcomer", version: "1.0", result: "quit" },
  ])
  assert.deepEqual(changes, [
    { app: "Telegram", version: "12.10", kind: "broke", result: "crashed", was: "ran" },
    { app: "Slack", version: "4.53", kind: "recovered", result: "ran", was: "quit" },
  ])
})

test("draft notices say what happens in plain words", () => {
  assert.match(noticeText("Telegram", "12.10", "crashed"), /^Copies of Telegram 12\.10 crash when they open\./)
  assert.match(noticeText("Slack", undefined, "quit"), /^Copies of Slack close right after they open\./)
})
