import assert from "node:assert/strict"
import { test } from "node:test"
import { canonicalProps, crashSignature } from "./telemetry.ts"

test("properties are only those allowed, with allowed values, in one order", () => {
  assert.equal(canonicalProps(["kind", "app", "result"], { result: "ok", kind: "copy", app: "com.tinyspeck.slackmacgap" }),
    '{"app":"com.tinyspeck.slackmacgap","kind":"copy","result":"ok"}')
  assert.equal(canonicalProps(["kind"], {}), "{}")
  assert.equal(canonicalProps(["kind"], { kind: "anything" }), null, "not a known kind")
  assert.equal(canonicalProps(["kind"], { path: "/Volumes/Work" }), null, "a property not allowed")
  assert.equal(canonicalProps(["app"], { app: "/Volumes/Work/Secret.app" }), null, "a path isn't a bundle ID")
  assert.equal(canonicalProps(["version"], { version: "1.5.0" }), '{"version":"1.5.0"}')
  assert.equal(canonicalProps(["kind"], { kind: 3 }), null)
  assert.equal(canonicalProps(["name"], { name: "Visual Studio Code" }), '{"name":"Visual Studio Code"}')
  assert.equal(canonicalProps(["app", "name"], { app: "com.example.app", name: "/Volumes/Work" }), '{"app":"com.example.app"}', "a name isn't a path: left out")
  assert.equal(canonicalProps(["version"], { version: "140.0.7339.80" }), '{"version":"140.0.7339.80"}')
})

test("a crash is known by Parallex's own frames", async () => {
  const uuid = "8F3C1A2B-1111-2222-3333-444455556666"
  const crash = await crashSignature({ kind: "crash", signal: 11, frames: [
    { binary: "SomeOtherLib", uuid, offset: 10 },
    { binary: "Parallex", uuid, offset: 0x1234 },
  ] })
  assert.ok(crash)
  assert.equal(crash.summary, "Signal 11 in Parallex +0x1234")
  assert.deepEqual(JSON.parse(crash.frames).map((f: { binary: string }) => f.binary), ["Parallex"], "never another app's code")
  const again = await crashSignature({ kind: "crash", signal: 11, frames: [{ binary: "Parallex", uuid, offset: 0x1234 }] })
  assert.equal(again?.signature, crash.signature)
  assert.equal(await crashSignature({ kind: "crash", frames: [{ binary: "Other", uuid, offset: 1 }] }), null)
  assert.equal(await crashSignature({ kind: "reboot", frames: [] }), null)
})
