import assert from "node:assert/strict"
import { test } from "node:test"
import { historyKey, labChanges, noticeText, resultsByMode } from "./labdiff.ts"

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
    { app: "Telegram", version: "12.10", mode: "copy", byDefault: true, kind: "broke", result: "crashed", was: "ran" },
    { app: "Slack", version: "4.53", mode: "copy", byDefault: true, kind: "recovered", result: "ran", was: "quit" },
  ])
})

test("nights are compared kind by kind; older nights were copies", () => {
  const previous = {
    // Before kinds were recorded: a copy's results.
    Edge: { version: "152", result: "quit" },
    Chrome: { version: "152", result: "ran" },
    Arc: { version: "1.1", mode: "wrapper", result: "ran", ownIdentity: { result: "quit" } },
    Slack: { version: "4.52", mode: "copy", result: "ran" },
  }
  const changes = labChanges(previous, [
    // The copy still quits; the wrapper, new tonight, has nothing to compare with.
    { app: "Edge", version: "153", mode: "wrapper", result: "ran", ownIdentity: { result: "quit" } },
    // The wrapper's crash isn't the copy's.
    { app: "Chrome", version: "153", mode: "wrapper", result: "crashed", ownIdentity: { result: "ran" } },
    { app: "Arc", version: "1.2", mode: "wrapper", result: "quit", ownIdentity: { result: "ran" } },
    { app: "Slack", version: "4.53", mode: "copy", result: "leaked" },
  ])
  assert.deepEqual(changes, [
    { app: "Arc", version: "1.2", mode: "copy", byDefault: false, kind: "recovered", result: "ran", was: "quit" },
    { app: "Arc", version: "1.2", mode: "wrapper", byDefault: true, kind: "broke", result: "quit", was: "ran" },
    { app: "Slack", version: "4.53", mode: "copy", byDefault: true, kind: "broke", result: "leaked", was: "ran" },
  ])
})

test("each kind's nights are kept under a name of their own", () => {
  assert.deepEqual(resultsByMode({ result: "ran" }), { copy: "ran" })
  assert.deepEqual(resultsByMode({ mode: "wrapper", result: "ran", ownIdentity: { result: "quit" } }), { wrapper: "ran", copy: "quit" })
  assert.deepEqual(resultsByMode({ mode: "wrapper", result: "ran" }), { wrapper: "ran" })
  assert.equal(historyKey("Slack", "copy"), "Slack")
  assert.equal(historyKey("Google Chrome", "wrapper"), "Google Chrome (wrapper)")
})

test("draft notices say what happens in plain words", () => {
  assert.match(noticeText("Telegram", "12.10", "crashed"), /^Copies of Telegram 12\.10 crash when they open\./)
  assert.match(noticeText("Slack", undefined, "quit"), /^Copies of Slack close right after they open\./)
  assert.match(noticeText("Arc", "1.2", "quit", "wrapper", true),
    /^Instances of Arc 1\.2 with a profile folder of their own close right after they open\..*use Arc itself/)
  assert.match(noticeText("Arc", "1.2", "crashed", "copy", false),
    /^Own-identity copies of Arc 1\.2 crash when they open\..*with Own identity off\.$/)
})
