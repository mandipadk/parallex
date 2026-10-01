import type { Env } from "./env"
import { alert } from "./guard"
import { latestLab } from "./lab"
import { LAB_BUNDLES, labChanges, noticeText, type Seen } from "./labdiff.ts"
import { logAction } from "./mission"

/**
 * Hourly: when a new night of the compatibility lab is published, compare
 * it with the last one seen. An app whose copies stopped running gets a
 * notice drafted (on the Notices page, for a person to check and publish)
 * and an alert; one that recovered gets an alert, so a notice can be taken
 * back.
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
  const next = { date: lab.date, apps: Object.fromEntries(lab.apps.map((a) => [a.app, { version: a.version, result: a.result }])) }
  const day = lab.date.slice(0, 10)
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO settings (key, value) VALUES ('lab_seen', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1`)
      .bind(JSON.stringify(next)),
    // The night, kept for each app's history.
    ...lab.apps.slice(0, 100).map((a) => env.DB.prepare(`INSERT OR REPLACE INTO lab_history (day, app, version, result) VALUES (?1, ?2, ?3, ?4)`)
      .bind(day, a.app, a.version ?? "", a.result)),
  ])

  for (const change of changes) {
    const which = change.version ? `${change.app} ${change.version}` : change.app
    if (change.kind === "broke") {
      const bundle = LAB_BUNDLES[change.app]
      if (bundle) {
        await env.DB.prepare(`INSERT INTO notice_drafts (created, status, bundle_id, name, versions, level, message, source)
          VALUES (?1, 'draft', ?2, ?3, ?4, ?5, ?6, 'lab')`)
          .bind(new Date().toISOString(), bundle, change.app, change.version?.split(" ")[0] || "*",
            change.result === "leaked" ? "warning" : "unsupported", noticeText(change.app, change.version, change.result)).run()
      }
      const text = `The nightly lab saw copies of ${which} ${change.result === "quit" ? "quit at launch" : change.result} (they ${change.was} before)${bundle ? "; a notice is drafted" : ""}`
      await logAction(env, "lab", text)
      await alert(env, `Parallex: ${text}. https://parallex.mandip.dev/admin#/notices`)
    } else {
      const text = `The nightly lab saw copies of ${which} running again`
      await logAction(env, "lab", text)
      await alert(env, `Parallex: ${text}; take back any notice about it. https://parallex.mandip.dev/admin#/notices`)
    }
  }
}

/** GET /api/v1/lab/history: each app's nights, newest first (at most 120). */
export async function labHistory(env: Env): Promise<Response> {
  const { results } = await env.DB.prepare(`SELECT day, app, version, result FROM lab_history
    WHERE day >= date('now', '-120 days') ORDER BY app, day DESC`).all<{ day: string; app: string; version: string; result: string }>()
  const apps: Record<string, { day: string; version: string; result: string }[]> = {}
  for (const row of results) (apps[row.app] ??= []).push({ day: row.day, version: row.version, result: row.result })
  return Response.json({ apps }, { headers: { "Cache-Control": "public, max-age=3600", "Access-Control-Allow-Origin": "*" } })
}
