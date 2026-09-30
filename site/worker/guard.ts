import type { Env } from "./env"
import { choose, loadRollout, publishedReleases, versionOf, type Rollout } from "./feed"
import { decide, DEFAULT_GUARDRAILS, readGuardrails, type Decision, type Guardrails } from "./guardrails.ts"
import { logAction, releases } from "./mission"

/**
 * Guardrails at work (see guardrails.ts for what they decide): the cron asks
 * each hour, and whatever they change is logged in Mission Control and, with
 * ALERT_WEBHOOK set, posted there.
 */

export async function loadGuardrails(env: Env): Promise<Guardrails> {
  const row = await env.DB.prepare(`SELECT value FROM settings WHERE key = 'guardrails'`).first<{ value: string }>().catch(() => null)
  try {
    return readGuardrails(JSON.parse(row?.value ?? "{}"))
  } catch {
    return { ...DEFAULT_GUARDRAILS }
  }
}

async function saveRollout(env: Env, rollout: Rollout): Promise<void> {
  await env.DB.prepare(`INSERT INTO settings (key, value) VALUES ('rollout', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1`)
    .bind(JSON.stringify(rollout)).run()
}

/** What the guardrails would do now, and why (for the dashboard too). */
export async function consider(env: Env, ctx: ExecutionContext, now = new Date()): Promise<{ config: Guardrails; decision: Decision; newest?: string }> {
  const [config, rollout, released] = await Promise.all([loadGuardrails(env), loadRollout(env), releases(env, ctx, 7, now)])
  const newest = released.published[0]
  const row = released.releases.find((r) => r.version === newest)
  const health = row
    ? { verdict: row.health.verdict, reasons: row.health.reasons, macs: row.macs }
    : { verdict: "early" as const, reasons: [], macs: 0 }
  return { config, decision: decide(config, rollout, newest, health, now), newest }
}

/** The hourly run: apply what the guardrails decide. */
export async function runGuardrails(env: Env, ctx: ExecutionContext, now = new Date()): Promise<void> {
  const { decision } = await consider(env, ctx, now)
  if (decision.action === "hold") return
  const rollout = await loadRollout(env)
  const changedAt = now.toISOString()
  let message: string
  switch (decision.action) {
    case "adopt":
      Object.assign(rollout, {
        version: decision.version, percent: decision.percent, paused: false, pausedBy: undefined, resumedByHand: undefined, changedAt,
      })
      message = `${decision.version} goes out to ${decision.percent}% of Macs`
      break
    case "advance":
      Object.assign(rollout, { percent: decision.percent, changedAt })
      message = `${rollout.version} now goes out to ${decision.percent}% of Macs. ${decision.reason}.`
      break
    case "pause":
      Object.assign(rollout, { paused: true, pausedBy: "guardrail" })
      message = `${rollout.version} paused at ${rollout.percent}%: ${decision.reason}. Resume it in Mission Control once it's fixed.`
      break
  }
  await saveRollout(env, rollout)
  await logAction(env, `guardrail ${decision.action}`, message)
  await alert(env, `Parallex: ${message}`)
}

/** Post to the alert webhook, if there is one (Slack and Discord both read these fields). */
export async function alert(env: Env, text: string): Promise<void> {
  if (!env.ALERT_WEBHOOK) return
  await fetch(env.ALERT_WEBHOOK, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text, content: text }),
  }).catch(() => undefined)
}

/** Turning them on or off, or changing the pace, from Mission Control. */
export async function setGuardrails(env: Env, ctx: ExecutionContext, form: FormData | null): Promise<void> {
  const current = await loadGuardrails(env)
  const hours = Number(form?.get("hours"))
  const minMacs = Number(form?.get("minMacs"))
  const next = readGuardrails({
    enabled: form?.has("enabled") ? form.get("enabled") === "1" : current.enabled,
    steps: current.steps,
    hours: Number.isFinite(hours) && hours > 0 ? hours : current.hours,
    minMacs: Number.isFinite(minMacs) && minMacs > 0 ? minMacs : current.minMacs,
    startBefore: current.startBefore,
  })
  const rollout = await loadRollout(env)
  if (next.enabled && !current.enabled) {
    // On. The release out now stays where it is (named, so it isn't
    // started over at the first step); later ones start at the first step
    // from the moment they're published, not only once the cron gets to them.
    const all = await publishedReleases(env, ctx)
    const offered = all.find((r) => !rollout.pulled.includes(versionOf(r)))
    const newest = offered ? versionOf(offered) : undefined
    if (newest && rollout.version !== newest) {
      // Its share now: everyone when every Mac is offered it.
      const share = choose(all, rollout, 0) === offered && choose(all, rollout, 99) === offered ? 100 : rollout.startPercent
      Object.assign(rollout, { version: newest, percent: share, paused: false, pausedBy: undefined, changedAt: new Date().toISOString() })
    }
    next.startBefore = rollout.startPercent
    rollout.startPercent = next.steps[0]
    await saveRollout(env, rollout)
  } else if (!next.enabled && current.enabled) {
    // Off: new releases start where they did before.
    rollout.startPercent = current.startBefore ?? 100
    next.startBefore = undefined
    await saveRollout(env, rollout)
  }
  await env.DB.prepare(`INSERT INTO settings (key, value) VALUES ('guardrails', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1`)
    .bind(JSON.stringify(next)).run()
  await logAction(env, "guardrails", next.enabled
    ? `On: ${next.steps.join("% → ")}%, at least ${next.hours} hours and ${next.minMacs} Macs a step`
    : "Off")
}
