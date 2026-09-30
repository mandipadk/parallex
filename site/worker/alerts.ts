import type { Env } from "./env"
import { alert } from "./guard"
import { apps, crashes, logAction, releases } from "./mission"

/**
 * Hourly, when ALERT_WEBHOOK is set: what's newly gone wrong, each told
 * once (alerts_sent keeps what was): a crash or hang on two or more Macs
 * that wasn't seen before yesterday, an app version whose copies started
 * quitting at launch, and a release judged failing.
 */
export async function checkAlerts(env: Env, ctx: ExecutionContext, now = new Date()): Promise<void> {
  if (!env.ALERT_WEBHOOK) return
  const yesterday = new Date(now.getTime() - 86_400_000).toISOString().slice(0, 10)
  const [crashData, appData, releaseData] = await Promise.all([crashes(env, 2, now), apps(env, 7, now), releases(env, ctx, 7, now)])
  const found: { key: string; text: string }[] = []
  for (const group of crashData.groups) {
    if (group.firstDay >= yesterday && group.macs >= 2) {
      found.push({ key: `crash:${group.signature}`, text: `New ${group.kind} on ${group.macs} Macs: ${group.summary} (first in ${group.firstVersion})` })
    }
  }
  for (const app of appData.apps) {
    for (const version of app.flaggedVersions) {
      found.push({ key: `app:${app.app}:${version}`, text: `Copies of ${app.name ?? app.app} ${version} are quitting at launch` })
    }
  }
  for (const release of releaseData.releases) {
    if (release.health.verdict === "failing") {
      found.push({ key: `release:${release.version}`, text: `${release.version} is failing: ${release.health.reasons.slice(0, 2).join("; ")}` })
    }
  }
  // A release or app version that's fine again can be told about again
  // if it goes wrong again; crashes are told once.
  const current = new Set(found.map((f) => f.key))
  const sent = await env.DB.prepare(`SELECT key FROM alerts_sent`).all<{ key: string }>()
  const cleared = sent.results.map((r) => r.key).filter((key) => !key.startsWith("crash:") && !current.has(key))
  if (cleared.length) {
    await env.DB.batch(cleared.map((key) => env.DB.prepare(`DELETE FROM alerts_sent WHERE key = ?1`).bind(key)))
  }
  const told = new Set(sent.results.map((r) => r.key).filter((key) => !cleared.includes(key)))
  for (const { key, text } of found.filter((f) => !told.has(f.key)).slice(0, 10)) {
    const fresh = await env.DB.prepare(`INSERT OR IGNORE INTO alerts_sent (key, at) VALUES (?1, ?2)`).bind(key, now.toISOString()).run()
    if (!fresh.meta.changes) continue
    await alert(env, `Parallex: ${text}. https://parallex.mandip.dev/admin`)
    await logAction(env, "alert", text)
  }
}
