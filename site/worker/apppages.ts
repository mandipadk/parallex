import { guides } from "../guides/apps.ts"
import { LAB_SLOT_ID, labBlock, labSlotContent, type Guide, type LabHistory, type LabRun } from "../guides/page.ts"
import type { Env } from "./env.ts"
import { latestLab } from "./lab.ts"

/**
 * The app pages (/apps/<slug>) are built with the lab results of the day
 * they were built. Served through here, their lab block is rendered again
 * with the latest run and each app's history, by the same code that built
 * it, so a page never waits for the site to be deployed again. When the
 * results can't be had, the page is served as it was built.
 */

/** The guide a path is for, when it's an app page with a lab result. */
export function guideFor(path: string, all: Guide[] = guides): Guide | undefined {
  const slug = /^\/apps\/([a-z0-9-]+)$/.exec(path)?.[1]
  return slug ? all.find((g) => g.slug === slug && g.labName) : undefined
}

/** The block to put in the page, or null to leave the built one (no
 *  results, or none for this app). */
export function liveBlock(guide: Guide, lab: LabRun | null, history: LabHistory | null): string | null {
  if (!lab || !history) return null
  const block = labBlock(guide, lab, history)
  return block ? labSlotContent(block) : null
}

/** Each app's nights in the lab, newest first, from the last 120 days. */
export async function readLabHistory(db: D1Database): Promise<LabHistory> {
  const { results } = await db.prepare(`SELECT day, app, version, result FROM lab_history
    WHERE day >= date('now', '-120 days') ORDER BY app, day DESC`).all<{ day: string; app: string; version: string; result: string }>()
  const apps: LabHistory = {}
  for (const row of results) (apps[row.app] ??= []).push({ day: row.day, version: row.version, result: row.result })
  return apps
}

type Live = { lab: LabRun | null; history: LabHistory | null }

// Kept in each isolate for a few minutes, so a page view is rarely a
// database query; a miss (the results unreachable) is retried sooner.
const KEEP = 5 * 60_000
const RETRY = 60_000
let kept: { at: number; ttl: number; live: Promise<Live> } | null = null

function liveLab(env: Env): Promise<Live> {
  const now = Date.now()
  if (kept && now - kept.at < kept.ttl) return kept.live
  const entry = {
    at: now,
    ttl: KEEP,
    live: Promise.all([latestLab(), readLabHistory(env.DB).catch(() => null)]).then(([lab, history]) => {
      if (!lab || !history) entry.ttl = RETRY
      return { lab, history }
    }),
  }
  kept = entry
  return entry.live
}

/** GET /apps/<slug>: the built page, with the latest lab results. */
export async function appPage(request: Request, env: Env): Promise<Response> {
  const guide = guideFor(new URL(request.url).pathname)
  if (!guide || request.method !== "GET") return env.ASSETS.fetch(request)
  // The page as built, asked for afresh: an answer of "not modified" would
  // leave nothing to fill in.
  const page = await env.ASSETS.fetch(new Request(request.url))
  if (!page.ok || !(page.headers.get("Content-Type") ?? "").startsWith("text/html")) return page
  let block: string | null = null
  try {
    const { lab, history } = await liveLab(env)
    block = liveBlock(guide, lab, history)
  } catch {
    block = null
  }
  if (block === null) return page
  const headers = new Headers(page.headers)
  headers.delete("ETag")
  headers.delete("Content-Length")
  headers.set("Cache-Control", "public, max-age=300")
  const filled = block
  return new HTMLRewriter()
    .on(`#${LAB_SLOT_ID}`, { element: (slot) => void slot.setInnerContent(filled, { html: true }) })
    .transform(new Response(page.body, { status: page.status, headers }))
}
