import assert from "node:assert/strict"
import { test } from "node:test"
import { parseIssue } from "./compatibility.ts"

test("reads the answers from a report's form", () => {
  const report = parseIssue({
    number: 12, html_url: "https://github.com/mandipadk/parallex/issues/12", title: "Slack: calls work",
    body: "### How does it work?\n\nWorks, with some problems\n\n### Setup\n\n```text\nApp: Slack 4.43.1 (com.tinyspeck.slackmacgap)\nMade as: own-identity copy\n```",
  })
  assert.deepEqual([report.verdict, report.name, report.version, report.bundleID], ["problems", "Slack", "4.43.1", "com.tinyspeck.slackmacgap"])
  assert.equal(parseIssue({ number: 1, html_url: "", title: "", body: "### How does it work?\n\nWorks great" }).verdict, "works")
  assert.equal(parseIssue({ number: 1, html_url: "", title: "", body: null }).verdict, null)
})
