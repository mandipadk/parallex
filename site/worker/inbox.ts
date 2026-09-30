import type { Env } from "./env"
import { publishedReleases, versionOf } from "./feed"
import { alert } from "./guard"
import { readDraft, readNote } from "./inbox-rules.ts"
import { logAction } from "./mission"
import type { Inbox, Notices } from "./mission-types"

/** Notes a day, from everyone together; beyond it, "try tomorrow". */
const NOTES_PER_DAY = 300

/** Something's Off: a note from the app (POST /api/v1/feedback). */
export async function feedbackIntake(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
  const length = Number(request.headers.get("Content-Length") ?? NaN)
  if (!Number.isFinite(length)) return new Response("Length required", { status: 411 })
  if (length > 16_000) return new Response("Too large", { status: 413 })
  const address = request.headers.get("CF-Connecting-IP") ?? "unknown"
  const network = address.includes(":") ? address.split(":").slice(0, 4).join(":") : address
  if (env.USAGE_LIMIT && !(await env.USAGE_LIMIT.limit({ key: `feedback:${network}` })).success) {
    return new Response("One note a minute, please.", { status: 429 })
  }
  let body: unknown
  try {
    body = JSON.parse((await request.text()).slice(0, 16_000))
  } catch {
    return new Response("Bad request", { status: 400 })
  }
  const note = readNote(body)
  if (!note) return new Response("Say what's off, in a few words.", { status: 400 })
  const day = new Date().toISOString().slice(0, 10)
  const today = await env.DB.prepare(`SELECT COUNT(*) AS n FROM feedback WHERE at >= ?1`).bind(day).first<{ n: number }>()
  if ((today?.n ?? 0) >= NOTES_PER_DAY) return new Response("Too many notes today; try tomorrow.", { status: 429 })

  const given = body as Record<string, unknown>
  const released = new Set((await publishedReleases(env, ctx)).map(versionOf))
  const version = typeof given.version === "string" && released.has(given.version) ? given.version : "other"
  const os = typeof given.os === "string" && /^\d{2}\.\d{1,2}$/.test(given.os) ? given.os : "other"
  const arch = given.arch === "arm64" || given.arch === "x86_64" ? given.arch : "other"
  await env.DB.prepare(`INSERT INTO feedback (at, version, os, arch, kind, app, app_version, facts, message, contact)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)`)
    .bind(new Date().toISOString(), version, os, arch, note.kind, note.app, note.appVersion, JSON.stringify(note.facts), note.message, note.contact).run()
  // Only that there's a note: its words stay in Mission Control.
  ctx.waitUntil(alert(env, `Parallex: a new note in the inbox, from ${version} on macOS ${os}${note.app && note.app !== "other" ? ` about ${note.app}` : ""}. https://parallex.mandip.dev/admin#/inbox`))
  return new Response(null, { status: 204 })
}

type Row = Record<string, unknown>

export async function inbox(env: Env): Promise<Inbox> {
  const { results } = await env.DB.prepare(`SELECT * FROM feedback ORDER BY CASE status WHEN 'new' THEN 0 WHEN 'seen' THEN 1 ELSE 2 END, at DESC LIMIT 200`)
    .all<Row>()
  const counts = await env.DB.prepare(`SELECT status, COUNT(*) AS n FROM feedback GROUP BY status`).all<Row>()
  return {
    notes: results.map((r) => {
      let facts: Record<string, unknown> = {}
      try {
        facts = JSON.parse(String(r.facts ?? "{}")) as Record<string, unknown>
      } catch {
        facts = {}
      }
      return {
        id: Number(r.id), at: String(r.at), status: String(r.status) as Inbox["notes"][number]["status"],
        version: String(r.version), os: String(r.os), arch: String(r.arch),
        kind: r.kind ? String(r.kind) : null, app: r.app ? String(r.app) : null, appVersion: r.app_version ? String(r.app_version) : null,
        facts, message: String(r.message), contact: r.contact ? String(r.contact) : null,
      }
    }),
    counts: Object.fromEntries(counts.results.map((r) => [String(r.status), Number(r.n)])),
  }
}

/** Seen, done (the reply address goes), reopen, or delete. */
export async function feedbackAction(env: Env, form: FormData | null): Promise<void> {
  const id = Number(form?.get("id"))
  const action = String(form?.get("action") ?? "")
  if (!Number.isInteger(id)) return
  const db = env.DB
  switch (action) {
    case "seen":
      await db.prepare(`UPDATE feedback SET status = 'seen' WHERE id = ?1 AND status = 'new'`).bind(id).run()
      return
    case "done":
      await db.prepare(`UPDATE feedback SET status = 'done', contact = NULL WHERE id = ?1`).bind(id).run()
      await logAction(env, "note done", `#${id}`)
      return
    case "reopen":
      await db.prepare(`UPDATE feedback SET status = 'seen' WHERE id = ?1`).bind(id).run()
      return
    case "delete":
      await db.prepare(`DELETE FROM feedback WHERE id = ?1`).bind(id).run()
      await logAction(env, "note deleted", `#${id}`)
      return
  }
}

export async function notices(env: Env, request: Request): Promise<Notices> {
  const { results } = await env.DB.prepare(`SELECT * FROM notice_drafts WHERE status <> 'deleted' ORDER BY id DESC LIMIT 100`).all<Row>()
  // What Parallex shows now: the signed file on the site.
  let live: Notices["live"] = []
  let issued: string | null = null
  try {
    const file = await env.ASSETS.fetch(new Request(new URL("/advisories.json", request.url)))
    const parsed = (await file.json()) as { issued?: string; apps?: Notices["live"] }
    live = parsed.apps ?? []
    issued = parsed.issued ?? null
  } catch {
    live = []
  }
  return {
    drafts: results.map((r) => ({
      id: Number(r.id), created: String(r.created), status: String(r.status) as Notices["drafts"][number]["status"],
      bundleID: String(r.bundle_id), name: String(r.name), versions: String(r.versions), level: String(r.level) as "warning" | "unsupported",
      message: String(r.message), website: r.website ? String(r.website) : null, source: String(r.source ?? ""),
      published: r.published ? String(r.published) : null,
    })),
    live,
    issued,
  }
}

/** Saving a draft, marking it ready to publish, or deleting it. A reason when it can't be done. */
export async function noticeAction(env: Env, form: FormData | null): Promise<string | null> {
  const fields: Record<string, string> = {}
  form?.forEach((value, key) => {
    if (typeof value === "string") fields[key] = value
  })
  const id = Number(fields.id)
  const db = env.DB
  if (fields.action === "delete" && Number.isInteger(id)) {
    await db.prepare(`UPDATE notice_drafts SET status = 'deleted' WHERE id = ?1 AND status <> 'published'`).bind(id).run()
    return null
  }
  if (fields.action === "unready" && Number.isInteger(id)) {
    await db.prepare(`UPDATE notice_drafts SET status = 'draft' WHERE id = ?1 AND status = 'ready'`).bind(id).run()
    return null
  }
  const draft = readDraft(fields)
  if (typeof draft === "string") return draft
  const status = fields.action === "ready" ? "ready" : "draft"
  const source = /^(apps|feedback:\d+)$/.test(fields.source ?? "") ? fields.source : ""
  if (Number.isInteger(id) && id > 0) {
    await db.prepare(`UPDATE notice_drafts SET bundle_id = ?2, name = ?3, versions = ?4, level = ?5, message = ?6, website = ?7, status = ?8
      WHERE id = ?1 AND status IN ('draft', 'ready')`)
      .bind(id, draft.bundleID, draft.name, draft.versions, draft.level, draft.message, draft.website, status).run()
  } else {
    await db.prepare(`INSERT INTO notice_drafts (created, status, bundle_id, name, versions, level, message, website, source)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`)
      .bind(new Date().toISOString(), status, draft.bundleID, draft.name, draft.versions, draft.level, draft.message, draft.website, source).run()
  }
  if (status === "ready") await logAction(env, "notice ready", `${draft.name} ${draft.versions}: ${draft.message.slice(0, 80)}`)
  return null
}
