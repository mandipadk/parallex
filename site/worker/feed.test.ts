// Run with: node --test --experimental-strip-types worker/*.test.ts
import assert from "node:assert/strict"
import { test } from "node:test"
import { choose, describe, type Rollout } from "./feed.ts"

const releases = [{ tag_name: "v0.21.0" }, { tag_name: "v0.20.0" }, { tag_name: "v0.19.0" }]
const everyone: Rollout = { percent: 100, paused: false, pulled: [], startPercent: 100 }
const tag = (r: { tag_name?: string } | undefined) => r?.tag_name

test("a release goes to everyone unless it's being rolled out", () => {
  assert.equal(tag(choose(releases, everyone, null)), "v0.21.0")
  assert.equal(tag(choose(releases, { ...everyone, version: "0.20.0", percent: 10 }, 50)), "v0.21.0", "the share is for another version")
})

test("a rollout reaches the Macs whose number is under its share", () => {
  const tenth: Rollout = { version: "0.21.0", percent: 10, paused: false, pulled: [], startPercent: 100 }
  assert.equal(tag(choose(releases, tenth, 3)), "v0.21.0")
  assert.equal(tag(choose(releases, tenth, 10)), "v0.20.0")
  assert.equal(tag(choose(releases, tenth, null)), "v0.20.0", "older Parallex and the installer wait")
  assert.equal(tag(choose(releases, { ...tenth, percent: 100 }, null)), "v0.21.0")
})

test("paused and pulled releases stop going out", () => {
  assert.equal(tag(choose(releases, { version: "0.21.0", percent: 50, paused: true, pulled: [], startPercent: 100 }, 1)), "v0.20.0")
  assert.equal(tag(choose(releases, { ...everyone, pulled: ["0.21.0"] }, 1)), "v0.20.0")
  assert.equal(tag(choose(releases, { ...everyone, pulled: ["0.21.0", "0.20.0"] }, 1)), "v0.19.0")
  assert.equal(choose(releases, { ...everyone, pulled: ["0.21.0", "0.20.0", "0.19.0"] }, 1), undefined, "nothing left: nothing offered")
})

test("a new release starts at the starting share until it has its own", () => {
  const staged: Rollout = { version: "0.20.0", percent: 100, paused: false, pulled: [], startPercent: 10 }
  assert.equal(tag(choose(releases, staged, 5)), "v0.21.0")
  assert.equal(tag(choose(releases, staged, 50)), "v0.20.0")
  assert.equal(tag(choose(releases, { ...staged, version: "0.21.0", percent: 50 }, 30)), "v0.21.0")
})

test("checks describe themselves only in known terms", () => {
  const released = new Set(["0.21.0"])
  const check = (headers: Record<string, string>) => describe(new Headers(headers), released)
  assert.deepEqual(check({ "X-Parallex-Version": "0.21.0", "X-Parallex-OS": "26.6", "X-Parallex-Arch": "arm64", "X-Parallex-Active": "day,week,bogus" }),
    { version: "0.21.0", os: "26.6", arch: "arm64", periods: ["check", "day", "week"] })
  assert.deepEqual(check({ "X-Parallex-Version": "9.9.9", "X-Parallex-OS": "99.1", "X-Parallex-Arch": "sparc" }),
    { version: "other", os: "other", arch: "other", periods: ["check"] })
  assert.deepEqual(check({ "X-Parallex-Installer": "1", "X-Parallex-OS": "15.4", "X-Parallex-Arch": "x86_64" }),
    { version: "installer", os: "15.4", arch: "x86_64", periods: ["install"] })
})
