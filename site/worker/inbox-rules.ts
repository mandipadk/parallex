/**
 * What a note from Something's Off may hold, and what a notice draft must
 * look like (the same rules Parallex reads notices by). Kept free of
 * imports so it can be tested on its own.
 */

const BUNDLE = /^[A-Za-z0-9][A-Za-z0-9.-]{1,99}$/
const VERSION = /^[0-9A-Za-z.() _+,-]{1,30}$/
const EMAIL = /^[A-Za-z0-9._+-]{1,64}@[A-Za-z0-9.-]{1,180}\.[A-Za-z]{2,24}$/
const KINDS = new Set(["copy", "sandboxed copy", "wrapper", "web"])

/** Facts the app attaches about the instance, and what each may be. */
const FACTS: Record<string, (value: unknown) => boolean> = {
  framework: (v) => typeof v === "string" && ["electron", "vscode-family", "chromium-browser", "firefox", "cef", "native"].includes(v),
  quitsAtLaunch: (v) => Number.isInteger(v) && (v as number) >= 0 && (v as number) <= 1000,
  isolation: (v) => typeof v === "string" && ["clean", "leak", "unchecked"].includes(v),
  running: (v) => typeof v === "boolean",
  guard: (v) => typeof v === "boolean",
  separateKeychain: (v) => typeof v === "boolean",
  pinnedVersion: (v) => typeof v === "boolean",
  sharesSettings: (v) => typeof v === "boolean",
  problems: (v) => Array.isArray(v) && v.length <= 8 && v.every((p) => typeof p === "string" && /^[a-zA-Z]{1,40}$/.test(p)),
}

export type Note = {
  message: string
  contact: string | null
  kind: string | null
  app: string | null
  appVersion: string | null
  facts: Record<string, unknown>
}

/** Plain text: no control characters, collapsed runs of blank lines. */
function clean(text: string, max: number): string {
  return text.replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, "").replace(/\n{3,}/g, "\n\n").trim().slice(0, max)
}

/** A note as sent, checked; null when there's nothing to keep. */
export function readNote(body: unknown): Note | null {
  if (!body || typeof body !== "object") return null
  const given = body as Record<string, unknown>
  const message = typeof given.message === "string" ? clean(given.message, 2000) : ""
  if (message.length < 3) return null
  const contact = typeof given.contact === "string" && EMAIL.test(given.contact.trim()) ? given.contact.trim() : null
  const instance = given.instance && typeof given.instance === "object" ? (given.instance as Record<string, unknown>) : null
  const kind = instance && typeof instance.kind === "string" && KINDS.has(instance.kind) ? instance.kind : null
  const app = instance && typeof instance.app === "string" && (instance.app === "other" || BUNDLE.test(instance.app)) ? instance.app : null
  const appVersion = app && app !== "other" && typeof instance?.appVersion === "string" && VERSION.test(instance.appVersion) ? instance.appVersion : null
  const facts: Record<string, unknown> = {}
  const givenFacts = instance?.facts && typeof instance.facts === "object" ? (instance.facts as Record<string, unknown>) : {}
  for (const [key, check] of Object.entries(FACTS)) {
    if (key in givenFacts && check(givenFacts[key])) facts[key] = givenFacts[key]
  }
  return { message, contact, kind, app, appVersion, facts }
}

function isVersion(text: string): boolean {
  return /^\d+(\.\d+)*$/.test(text)
}

/** A notice's version range: *, 4.2, <4.2, <=4.2, >4.2, >=4.2, 4.1...4.3, comma-separated. */
export function isValidRange(range: string): boolean {
  const trimmed = range.trim()
  if (!trimmed || trimmed === "*") return true
  return trimmed.split(",").every((raw) => {
    const part = raw.trim()
    if (part.includes("...")) {
      const bounds = part.split("...")
      return bounds.length === 2 && bounds.every((b) => isVersion(b.trim()))
    }
    for (const prefix of ["<=", ">=", "<", ">"]) {
      if (part.startsWith(prefix)) return isVersion(part.slice(prefix.length).trim())
    }
    return isVersion(part)
  })
}

export type Draft = { bundleID: string; name: string; versions: string; level: "warning" | "unsupported"; message: string; website: string | null }

/** A notice draft, checked; a reason when it can't be kept. */
export function readDraft(form: Record<string, string>): Draft | string {
  const bundleID = (form.bundle ?? "").trim()
  if (!BUNDLE.test(bundleID)) return "That isn't an app's bundle ID."
  const name = clean(form.name ?? "", 60)
  if (!name) return "Give the app's name."
  const versions = (form.versions ?? "").trim() || "*"
  if (!isValidRange(versions)) return "Versions are like 11.5, >=11.5, 11.4...11.6, or * for all."
  const level = form.level === "unsupported" ? "unsupported" : form.level === "warning" ? "warning" : null
  if (!level) return "Choose warning or unsupported."
  const message = clean(form.message ?? "", 400)
  if (message.length < 10) return "Say what's wrong, in a sentence or two."
  const website = (form.website ?? "").trim()
  if (website && !/^https:\/\/[^\s<>"]{3,200}$/.test(website)) return "The website must be an https address."
  return { bundleID, name, versions, level, message, website: website || null }
}
