import assert from "node:assert/strict"
import { test } from "node:test"
import { guides } from "../guides/apps.ts"
import { guidePage, LAB_SLOT_ID, type LabHistory, type LabRun } from "../guides/page.ts"
import { guideFor, liveBlock } from "./apppages.ts"
import { parseLab } from "./lab.ts"

const slack = guides.find((g) => g.slug === "slack")!

const run = (date: string, result: string, version = "4.52.155"): LabRun => ({
  date, macos: "26.6.2", apps: [{ app: "Slack", version, result, leaks: 0, blocked: 0 }],
})

const history: LabHistory = {
  Slack: [
    { day: "2026-10-01", version: "4.52.155", result: "ran" },
    { day: "2026-09-30", version: "4.52.150", result: "ran" },
  ],
}

/** What the worker does with HTMLRewriter: the slot's contents, replaced. */
function fill(html: string, content: string): string {
  const open = `<div id="${LAB_SLOT_ID}" class="lab-slot">`
  const start = html.indexOf(open)
  assert.notEqual(start, -1, "the page has the slot")
  assert.equal(html.indexOf(open, start + 1), -1, "only once")
  const end = html.indexOf("</div>", start)
  return html.slice(0, start + open.length) + content + html.slice(end)
}

test("only app pages with lab results are filled in", () => {
  assert.equal(guideFor("/apps/slack"), slack)
  assert.equal(guideFor("/apps/slack.html"), undefined)
  assert.equal(guideFor("/apps/slack/"), undefined)
  assert.equal(guideFor("/apps/nothing"), undefined)
  assert.equal(guideFor("/apps/teams"), undefined)
  assert.equal(guideFor("/apps"), undefined)
})

test("a page filled in live reads exactly as if it had been built then", () => {
  const built = guidePage(slack, guides, run("2026-09-30T14:00:00Z", "quit"), {})
  const tonight = run("2026-10-02T14:57:18Z", "ran")
  const live = fill(built, liveBlock(slack, tonight, history)!)
  assert.equal(live, guidePage(slack, guides, tonight, history))
  assert.match(live, /On October 2, 2026, on macOS 26\.6\.2, the copy ran/)
  assert.doesNotMatch(live, /didn't run cleanly/)
})

test("a page built without results gets them", () => {
  const built = guidePage(slack, guides, null, null)
  assert.doesNotMatch(built, /Tested every night/)
  const tonight = run("2026-10-02T14:57:18Z", "crashed")
  assert.equal(fill(built, liveBlock(slack, tonight, history)!), guidePage(slack, guides, tonight, history))
})

test("the night just run counts before the history has it", () => {
  const block = liveBlock(slack, run("2026-10-02T14:57:18Z", "ran"), history)!
  assert.match(block, /run clean on all 3 nights since September 30\./)
})

test("without results, the page stays as it was built", () => {
  assert.equal(liveBlock(slack, null, history), null)
  assert.equal(liveBlock(slack, run("2026-10-02T14:57:18Z", "ran"), null), null)
  assert.equal(liveBlock(slack, { date: "2026-10-02T14:57:18Z", macos: "26.6.2", apps: [] }, history), null)
  assert.equal(liveBlock(slack, { date: "not a date", macos: "26.6.2", apps: run("x", "ran").apps }, history), null)
})

test("fields the lab adds later don't get in the way", () => {
  const lab = parseLab({
    date: "2026-10-02T14:57:18Z", macos: "26.6.2", parallex: "2388aaf",
    apps: [{ app: "Slack", version: "4.52.155", result: "ran", leaks: 0, mode: "copy", ownIdentity: { signed: true, team: "X" } }],
  })
  assert.ok(lab)
  assert.match(liveBlock(slack, lab, {})!, /Slack 4\.52\.155 every night/)
})

test("a browser's page shows its profile instance's result, with its own nights", () => {
  const chrome = guides.find((g) => g.slug === "chrome")!
  assert.equal(guideFor("/apps/chrome"), chrome)
  const nights: LabHistory = {
    "Google Chrome": [{ day: "2026-10-01", version: "152", result: "quit" }, { day: "2026-09-30", version: "152", result: "quit" }],
    "Google Chrome (wrapper)": [{ day: "2026-10-01", version: "152", result: "ran" }],
  }
  const lab = (own: string): LabRun => ({
    date: "2026-10-02T14:57:18Z", macos: "26.6.2",
    apps: [{ app: "Google Chrome", version: "153", mode: "wrapper", result: "ran", leaks: 0, ownIdentity: { result: own } }],
  })
  const block = liveBlock(chrome, lab("ran"), nights)!
  assert.match(block, /makes a fresh instance of Google Chrome 153 \(the app itself, opened with a profile folder of its own/)
  assert.match(block, /on macOS 26\.6\.2, it ran, and nothing reached the original's data\./)
  assert.match(block, /Its instances have run clean on all 2 nights since October 1\./)
  assert.match(block, /Made as its own copy instead \(Own identity\), it ran clean too\./)
  assert.doesNotMatch(block, /fresh copy|the copy ran/)
  assert.match(liveBlock(chrome, lab("quit"), nights)!, /Made as its own copy instead \(Own identity\), it didn't run cleanly \(quit at launch\)\./)
  // A night from before the lab made wrappers was a copy's: not this page's.
  const old: LabRun = { date: "2026-10-01T14:57:18Z", macos: "26.6.2", apps: [{ app: "Google Chrome", version: "152", result: "ran" }] }
  assert.equal(liveBlock(chrome, old, nights), null)
})

test("the page's structured data stays valid", () => {
  const html = guidePage(slack, guides, run("2026-10-02T14:57:18Z", "ran"), history)
  const scripts = [...html.matchAll(/<script type="application\/ld\+json">(.*?)<\/script>/g)]
  assert.equal(scripts.length, 2)
  for (const [, data] of scripts) assert.ok(JSON.parse(data)["@type"])
})
