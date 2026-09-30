/**
 * What Telemetry 2 accepts: event and gauge names, their properties and
 * values, and crash signatures (see report.ts). Kept free of imports so
 * it can be tested on its own.
 */

export type Value = "kind" | "framework" | "app" | "name" | "result" | "step" | "mode" | "duration" | "version" | "reason" | "feature" | "command" | "source"

const ENUMS: Record<string, Set<string>> = {
  kind: new Set(["copy", "sandboxed copy", "wrapper", "web"]),
  framework: new Set(["electron", "vscode-family", "chromium-browser", "firefox", "cef", "native"]),
  result: new Set(["ok", "failed", "ran", "quit at launch", "clean", "leak", "cancelled"]),
  step: new Set(["inspect", "clone", "sign", "build", "keychain", "register", "download", "verify", "install", "relaunch", "welcome", "privacy", "first-instance", "done", "other"]),
  mode: new Set(["now", "staged", "launcher"]),
  duration: new Set(["<5s", "<15s", "<60s", "60s+"]),
  reason: new Set(["manual", "daily", "before-refresh", "before-restore"]),
  feature: new Set([
    "workspaces", "throwaway", "hideFromDock", "menuBarIcon", "shortcut", "quitWhenUnused", "openAtLaunch", "shareMCPServers",
    "signInLinks", "webLinks", "snapshots", "dailySnapshots", "pinnedVersion", "persona", "proxy", "shareSettings", "guard",
    "separateKeychain", "privateItems", "health", "versions", "run", "shell",
  ]),
  command: new Set([
    "create", "list", "open", "edit", "repair", "remove", "duplicate", "copy-data", "check", "storage", "health", "snapshot",
    "versions", "workspace", "run", "shell", "links", "export", "import", "doctor", "report", "usage", "notices", "apps",
  ]),
  source: new Set(["app", "cli", "shortcuts", "menu bar"]),
}
const BUNDLE = /^[A-Za-z0-9][A-Za-z0-9.-]{1,99}$/
const VERSION = /^[0-9A-Za-z.() _+,-]{1,30}$/
/** A well-known app's own name ("Visual Studio Code"). */
const NAME = /^[\p{L}\p{N} .&+()'’-]{1,40}$/u

/** Each event and gauge, and the properties it may carry. */
export const EVENTS: Record<string, Value[]> = {
  "instance.created": ["kind", "framework", "app", "result", "step", "source"],
  "instance.opened": ["kind", "app", "version", "result"],
  "copy.refreshed": ["app", "version", "result", "mode", "duration"],
  "update.installed": ["version", "result", "step"],
  "isolation.checked": ["app", "result"],
  "snapshot.taken": ["reason"],
  "snapshot.restored": [],
  "version.changed": ["app"],
  "feature.used": ["feature"],
  "onboarding.step": ["step"],
  "cli.command": ["command"],
}
export const GAUGES: Record<string, Value[]> = {
  instances: ["kind"],
  app: ["app", "version", "kind", "name"],
  feature: ["feature"],
  "guard.blocked": [],
  "app.other": [],
  // A well-known website with web instances (its host, in "app").
  website: ["app"],
  "website.other": [],
}

export const whole = (value: unknown, max: number): number | null =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? Math.min(max, Math.floor(value)) : null

/** Properties that are only descriptive: an odd one is left out, not the
 *  whole event. */
const OPTIONAL = new Set(["name", "version"])

/** The properties as stored: only those allowed, values checked, keys sorted. */
export function canonicalProps(allowed: Value[], props: unknown): string | null {
  const given = props && typeof props === "object" ? (props as Record<string, unknown>) : {}
  const kept: Record<string, string> = {}
  for (const key of Object.keys(given)) {
    if (!allowed.includes(key as Value)) return null
    const value = given[key]
    const ok = typeof value === "string" && (key === "app" ? BUNDLE.test(value) || value === "other"
      : key === "version" ? VERSION.test(value)
      : key === "name" ? NAME.test(value)
      : ENUMS[key]?.has(value) ?? false)
    if (!ok) {
      if (OPTIONAL.has(key)) continue
      return null
    }
    kept[key] = value as string
  }
  return JSON.stringify(Object.fromEntries(Object.keys(kept).sort().map((key) => [key, kept[key]])))
}

type Frame = { binary?: unknown; uuid?: unknown; offset?: unknown }
export type Crash = { kind?: unknown; signal?: unknown; exceptionType?: unknown; frames?: unknown; n?: unknown }

const BINARIES = new Set(["Parallex", "parallex", "parallex-launcher", "parallex-router", "parallex-web", "libparallexhome.dylib", "libparallexgroups.dylib"])

/** A crash's signature: kind, signal and Parallex's own top frames. */
export async function crashSignature(crash: Crash): Promise<{ signature: string; summary: string; frames: string } | null> {
  const kind = crash.kind === "crash" || crash.kind === "hang" ? crash.kind : null
  if (!kind || !Array.isArray(crash.frames)) return null
  const frames = (crash.frames as Frame[]).slice(0, 12).flatMap((frame) => {
    const binary = typeof frame.binary === "string" && BINARIES.has(frame.binary) ? frame.binary : null
    const uuid = typeof frame.uuid === "string" && /^[0-9A-F-]{36}$/i.test(frame.uuid) ? frame.uuid.toUpperCase() : null
    const offset = whole(frame.offset, 2 ** 40)
    return binary && uuid && offset !== null ? [{ binary, uuid, offset }] : []
  })
  if (!frames.length) return null
  const signal = whole(crash.signal, 64)
  const exceptionType = whole(crash.exceptionType, 64)
  const key = JSON.stringify({ kind, signal, exceptionType, frames: frames.slice(0, 8).map((f) => `${f.binary}+${f.offset}`) })
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(key)))
  const signature = [...digest.slice(0, 8)].map((b) => b.toString(16).padStart(2, "0")).join("")
  const top = frames[0]
  const summary = `${kind === "hang" ? "Hang" : signal !== null ? `Signal ${signal}` : "Crash"} in ${top.binary} +0x${top.offset.toString(16)}`
  return { signature, summary, frames: JSON.stringify(frames) }
}

