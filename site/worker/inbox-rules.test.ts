import assert from "node:assert/strict"
import { test } from "node:test"
import { isValidRange, readDraft, readNote } from "./inbox-rules.ts"

test("a note keeps its words, a typed address and only known facts", () => {
  const note = readNote({
    message: "Telegram copy closes right away\u0007 after the update.",
    contact: " me@example.com ",
    instance: {
      kind: "copy", app: "ru.keepcoder.Telegram", appVersion: "11.5", name: "Telegram Work",
      facts: { quitsAtLaunch: 4, isolation: "clean", path: "/Volumes/Work/x", problems: ["cloneOutdated"] },
    },
  })
  assert.ok(note)
  assert.equal(note.message, "Telegram copy closes right away after the update.")
  assert.equal(note.contact, "me@example.com")
  assert.deepEqual(note.facts, { quitsAtLaunch: 4, isolation: "clean", problems: ["cloneOutdated"] }, "no path, no name")
  assert.equal(note.appVersion, "11.5")
})

test("nothing to say, or a bad address, isn't kept", () => {
  assert.equal(readNote({ message: "  " }), null)
  assert.equal(readNote({ message: "hello there", contact: "not an address" })?.contact, null)
  assert.equal(readNote({ message: "hello there", contact: "a@b.com?cc=x%40y.com" })?.contact, null, "nothing that adds to a mailto link")
  assert.equal(readNote({ message: "hello there", instance: { app: "other", appVersion: "1.0" } })?.appVersion, null, "no version for other apps")
})

test("notice ranges follow Parallex's rules", () => {
  for (const ok of ["*", "11.5", ">=11.5", "<4.2, >5", "11.4...11.6"]) assert.ok(isValidRange(ok), ok)
  for (const bad of ["11.x", ">=", "1...2...3", "latest"]) assert.ok(!isValidRange(bad), bad)
})

test("a draft needs an app, a range, a level and a message", () => {
  const draft = readDraft({ bundle: "ru.keepcoder.Telegram", name: "Telegram", versions: "11.5", level: "warning", message: "Copies of Telegram 11.5 quit at launch." })
  assert.deepEqual(draft, { bundleID: "ru.keepcoder.Telegram", name: "Telegram", versions: "11.5", level: "warning", message: "Copies of Telegram 11.5 quit at launch.", website: null })
  assert.equal(typeof readDraft({ bundle: "x y", name: "a", level: "warning", message: "long enough message" }), "string")
  assert.equal(typeof readDraft({ bundle: "a.b", name: "a", versions: "new", level: "warning", message: "long enough message" }), "string")
  assert.equal(typeof readDraft({ bundle: "a.b", name: "a", level: "warning", message: "long enough", website: "http://x.com" }), "string")
})
