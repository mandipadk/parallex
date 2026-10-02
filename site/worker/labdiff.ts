/**
 * What changed between two nights of the compatibility lab: apps whose
 * instances stopped running (or started leaking), and apps that recovered.
 * Kept free of imports so it can be tested on its own.
 *
 * Each app is tried the way New Instance makes it by default: an
 * own-identity copy, or for browsers a wrapper (a profile folder of its own),
 * and then a copy too. A night is compared with the last one kind by kind;
 * nights from before kinds were recorded only made copies.
 */

export type Mode = "copy" | "wrapper"
export type Night = { app: string; version?: string; mode?: string; result: string; ownIdentity?: { result: string } }
export type Seen = Omit<Night, "app">
export type Change = {
  app: string
  version?: string
  /** Which kind of instance it's about, and whether it's the one New Instance makes. */
  mode: Mode
  byDefault: boolean
  kind: "broke" | "recovered"
  result: string
  was: string
}

/** Results that mean an instance works as it should. */
const fine = (result: string) => result === "ran"
/** Results that mean it doesn't (not "not installed" or "not copied", which say nothing about the app). */
const broken = (result: string) => result === "quit" || result === "crashed" || result === "leaked"

/** How the app's default instance was made. */
export const defaultMode = (night: { mode?: string }): Mode => (night.mode === "wrapper" ? "wrapper" : "copy")

/** A night's results, by kind of instance. */
export function resultsByMode(night: Seen): Partial<Record<Mode, string>> {
  if (defaultMode(night) === "copy") return { copy: night.result }
  return { wrapper: night.result, ...(night.ownIdentity ? { copy: night.ownIdentity.result } : {}) }
}

/** Where an app's nights of one kind are kept: a copy's under the app's
 *  name, as they always were; a wrapper's beside it. */
export const historyKey = (app: string, mode: Mode) => (mode === "copy" ? app : `${app} (wrapper)`)

export function labChanges(previous: Record<string, Seen>, current: Night[]): Change[] {
  const changes: Change[] = []
  for (const now of current) {
    const before = previous[now.app]
    if (!before) continue
    const then = resultsByMode(before)
    const results = resultsByMode(now)
    for (const mode of ["copy", "wrapper"] as const) {
      const was = then[mode]
      const result = results[mode]
      if (was === undefined || result === undefined) continue
      const change = { app: now.app, version: now.version, mode, byDefault: mode === defaultMode(now), result, was }
      if (fine(was) && broken(result)) changes.push({ ...change, kind: "broke" })
      else if (broken(was) && fine(result)) changes.push({ ...change, kind: "recovered" })
    }
  }
  return changes
}

/** What to call an app's instances of a kind, in a sentence. */
export function instancesOf(which: string, mode: Mode, byDefault: boolean): string {
  if (mode === "wrapper") return `Instances of ${which} with a profile folder of their own`
  return byDefault ? `Copies of ${which}` : `Own-identity copies of ${which}`
}

/** The lab's apps by bundle ID, for drafting a notice about one. */
export const LAB_BUNDLES: Record<string, string> = {
  Obsidian: "md.obsidian", "Visual Studio Code": "com.microsoft.VSCode", Zed: "dev.zed.Zed", IINA: "com.colliderli.iina",
  VLC: "org.videolan.vlc", Discord: "com.hnc.Discord", Slack: "com.tinyspeck.slackmacgap", Spotify: "com.spotify.client",
  Claude: "com.anthropic.claudefordesktop", ChatGPT: "com.openai.codex", Cursor: "com.todesktop.230313mzl4w4u92",
  Notion: "notion.id", Telegram: "ru.keepcoder.Telegram", Signal: "org.whispersystems.signal-desktop", Figma: "com.figma.Desktop",
  WhatsApp: "net.whatsapp.WhatsApp", Postman: "com.postmanlabs.mac", Linear: "com.linear",
  "Google Chrome": "com.google.Chrome", Firefox: "org.mozilla.firefox", "Brave Browser": "com.brave.Browser",
  "Microsoft Edge": "com.microsoft.edgemac", Arc: "company.thebrowser.Browser", Vivaldi: "com.vivaldi.Vivaldi",
  "zoom.us": "us.zoom.xos", "Microsoft Teams": "com.microsoft.teams2", Element: "im.riot.app", Mattermost: "Mattermost.Desktop",
  Warp: "dev.warp.Warp-Stable", Ghostty: "com.mitchellh.ghostty", "GitHub Desktop": "com.github.GitHubClient",
  Insomnia: "com.insomnia.app", "Notion Calendar": "com.cron.electron", Miro: "com.electron.realtimeboard",
  Thunderbird: "org.mozilla.thunderbird",
}

/** Plain words for a lab result, for a draft notice. */
export function noticeText(app: string, version: string | undefined, result: string, mode: Mode = "copy", byDefault = true): string {
  const which = version ? `${app} ${version}` : app
  const subject = instancesOf(which, mode, byDefault)
  // An own-identity copy of an app whose instances aren't copies by
  // default: the usual kind still works.
  const instead = byDefault ? `use ${app} itself for one of the accounts` : `make its instances with Own identity off`
  const them = mode === "copy" ? "copies" : "these instances"
  switch (result) {
    case "crashed": return `${subject} crash when they open. Parallex is looking into it; until then, ${instead}.`
    case "leaked": return `${subject} can reach some of the original's data. Parallex is looking into it; keep sensitive accounts out of ${them} until it's fixed.`
    default: return `${subject} close right after they open. Parallex is looking into it; until then, ${instead}.`
  }
}
