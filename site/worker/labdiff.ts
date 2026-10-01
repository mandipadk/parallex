/**
 * What changed between two nights of the compatibility lab: apps whose
 * copies stopped running (or started leaking), and apps that recovered.
 * Kept free of imports so it can be tested on its own.
 */

export type Seen = { version?: string; result: string }
export type Change = { app: string; version?: string; kind: "broke" | "recovered"; result: string; was: string }

/** Results that mean a copy works as it should. */
const fine = (result: string) => result === "ran"
/** Results that mean it doesn't (not "not installed" or "not copied", which say nothing about the app). */
const broken = (result: string) => result === "quit" || result === "crashed" || result === "leaked"

export function labChanges(previous: Record<string, Seen>, current: { app: string; version?: string; result: string }[]): Change[] {
  const changes: Change[] = []
  for (const now of current) {
    const before = previous[now.app]
    if (!before) continue
    if (fine(before.result) && broken(now.result)) {
      changes.push({ app: now.app, version: now.version, kind: "broke", result: now.result, was: before.result })
    } else if (broken(before.result) && fine(now.result)) {
      changes.push({ app: now.app, version: now.version, kind: "recovered", result: now.result, was: before.result })
    }
  }
  return changes
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
export function noticeText(app: string, version: string | undefined, result: string): string {
  const which = version ? `${app} ${version}` : app
  switch (result) {
    case "crashed": return `Copies of ${which} crash when they open. Parallex is looking into it; until then, use ${app} itself for one of the accounts.`
    case "leaked": return `Copies of ${which} can reach some of the original's data. Parallex is looking into it; keep sensitive accounts out of copies until it's fixed.`
    default: return `Copies of ${which} close right after they open. Parallex is looking into it; until then, use ${app} itself for one of the accounts.`
  }
}
