import { readLabHistory } from "./apppages"
import type { Env } from "./env"
import { alert } from "./guard"
import { latestLab } from "./lab"
import { historyKey, instancesOf, LAB_BUNDLES, labChanges, noticeText, resultsByMode, type Mode, type Seen } from "./labdiff.ts"
import { logAction } from "./mission"

/**
 * Hourly: when a new night of the compatibility lab is published, compare
 * it with the last one seen, each kind of instance with its own kind. An
 * app whose instances stopped running gets a notice drafted (on the Notices
 * page, for a person to check and publish) and an alert; one that recovered
 * gets an alert, so a notice can be taken back.
 */
export async function watchLab(env: Env): Promise<void> {
  const lab = await latestLab()
  if (!lab || !lab.apps.length) return
  const stored = await env.DB.prepare(`SELECT value FROM settings WHERE key = 'lab_seen'`).first<{ value: string }>()
  let seen: { date?: string; apps?: Record<string, Seen> } = {}
  try {
    seen = JSON.parse(stored?.value ?? "{}")
  } catch {
    seen = {}
  }
  if (seen.date === lab.date) return
  const changes = seen.apps ? labChanges(seen.apps, lab.apps) : []
  const next = {
    date: lab.date,
    apps: Object.fromEntries(lab.apps.map((a) => [a.app, { version: a.version, mode: a.mode, result: a.result, ownIdentity: a.ownIdentity && { result: a.ownIdentity.result } }])),
  }
  const day = lab.date.slice(0, 10)
  // The night, kept for each app's history: each kind of instance tried
  // under its own name (see historyKey).
  const nights = lab.apps.slice(0, 100).flatMap((a) =>
    Object.entries(resultsByMode(a)).map(([mode, result]) => ({ app: historyKey(a.app, mode as Mode), version: a.version ?? "", result })))
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO settings (key, value) VALUES ('lab_seen', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1`)
      .bind(JSON.stringify(next)),
    ...nights.map((n) => env.DB.prepare(`INSERT OR REPLACE INTO lab_history (day, app, version, result) VALUES (?1, ?2, ?3, ?4)`)
      .bind(day, n.app, n.version, n.result)),
  ])

  for (const change of changes) {
    const which = change.version ? `${change.app} ${change.version}` : change.app
    const subject = instancesOf(which, change.mode, change.byDefault).replace(/^\w/, (c) => c.toLowerCase())
    if (change.kind === "broke") {
      const bundle = LAB_BUNDLES[change.app]
      if (bundle) {
        // Only the kind New Instance makes can say an app doesn't work.
        const level = change.result === "leaked" || !change.byDefault ? "warning" : "unsupported"
        await env.DB.prepare(`INSERT INTO notice_drafts (created, status, bundle_id, name, versions, level, message, source)
          VALUES (?1, 'draft', ?2, ?3, ?4, ?5, ?6, 'lab')`)
          .bind(new Date().toISOString(), bundle, change.app, change.version?.split(" ")[0] || "*",
            level, noticeText(change.app, change.version, change.result, change.mode, change.byDefault)).run()
      }
      const text = `The nightly lab saw ${subject} ${change.result === "quit" ? "quit at launch" : change.result} (they ${change.was} before)${bundle ? "; a notice is drafted" : ""}`
      await logAction(env, "lab", text)
      await alert(env, `Parallex: ${text}. https://parallex.mandip.dev/admin#/notices`)
    } else {
      const text = `The nightly lab saw ${subject} running again`
      await logAction(env, "lab", text)
      await alert(env, `Parallex: ${text}; take back any notice about it. https://parallex.mandip.dev/admin#/notices`)
    }
  }
}

/** GET /api/v1/lab/history: each app's nights, newest first (at most 120). */
export async function labHistory(env: Env): Promise<Response> {
  return Response.json({ apps: await readLabHistory(env.DB) }, { headers: { "Cache-Control": "public, max-age=3600", "Access-Control-Allow-Origin": "*" } })
}
