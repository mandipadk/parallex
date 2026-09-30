import assert from "node:assert/strict"
import { test } from "node:test"
import { isLater, notesSince } from "./notes.ts"

const releases = [
  { tag_name: "v1.6.0", body: "Six." },
  { tag_name: "v1.5.0", body: "Five." },
  { tag_name: "v1.4.0", body: "" },
  { tag_name: "v1.3.0", body: "Three." },
]
const url = "https://github.com/mandipadk/parallex/releases"

test("versions compare by number", () => {
  assert.ok(isLater("1.10.0", "1.9.2"))
  assert.ok(isLater("v1.6.0", "1.5"))
  assert.ok(!isLater("1.5.0", "1.5.0"))
})

test("one release behind: its own notes", () => {
  assert.equal(notesSince(releases, releases[0], "1.5.0", url), "Six.")
})

test("several behind: every release missed, newest first, each headed", () => {
  const notes = notesSince(releases, releases[0], "1.3.0", url)
  assert.equal(notes, "## Parallex 1.6.0\n\nSix.\n\n## Parallex 1.5.0\n\nFive.\n\n## Parallex 1.4.0\n\nBug fixes and improvements.")
})

test("an older release offered (rollout) stops at it", () => {
  assert.equal(notesSince(releases, releases[1], "1.3.0", url), "## Parallex 1.5.0\n\nFive.\n\n## Parallex 1.4.0\n\nBug fixes and improvements.")
})

test("an unknown current version gets the offered notes", () => {
  assert.equal(notesSince(releases, releases[0], "", url), "Six.")
  assert.equal(notesSince(releases, releases[0], "other", url), "Six.")
})

test("a long way behind: the newest eight, then a link", () => {
  const many = Array.from({ length: 12 }, (_, i) => ({ tag_name: `v1.${12 - i}.0`, body: `N${12 - i}` }))
  const notes = notesSince(many, many[0], "1.0.0", url)
  assert.equal(notes.match(/^## Parallex/gm)?.length, 8)
  assert.match(notes, /## And before that\n\n4 more releases since 1\.0\.0: https:/)
})
