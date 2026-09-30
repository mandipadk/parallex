/**
 * Guardrails: the newest release goes out by itself while it stays healthy,
 * and stops by itself when it isn't. Each hour the cron asks `decide` what
 * to do with the rollout, given the release's verdict (see health.ts).
 * Kept free of imports so it can be tested on its own.
 */

export type Guardrails = {
  enabled: boolean
  /** The shares a release moves through, in order. */
  steps: number[]
  /** How long a release stays at a share, at least, before the next. */
  hours: number
  /** Macs that must have reported from it before it moves on. */
  minMacs: number
  /** The rollout's starting share before they were turned on, given back
   *  when they're turned off. */
  startBefore?: number
}

/** Fewer Macs than this and a verdict is only "early" (see health.ts). */
const LEAST_MACS = 5

/** Starting at 10%: at 1%, too few Macs would ever report for a verdict. */
export const DEFAULT_GUARDRAILS: Guardrails = { enabled: false, steps: [10, 50, 100], hours: 24, minMacs: 5 }

/** With fewer Macs reporting than asked for, a step still passes after
 *  this many times its hours with nothing wrong reported. */
const QUIET_STEPS = 3

export type RolloutState = {
  version?: string
  percent: number
  paused: boolean
  pulled: string[]
  startPercent: number
  /** When the share last changed (ISO). */
  changedAt?: string
  /** Who paused it; a hand pause is left alone. */
  pausedBy?: "guardrail" | "hand"
  /** A release resumed by hand after a guardrail paused it: not paused
   *  again for the same trouble. */
  resumedByHand?: string
}

export type Decision =
  | { action: "adopt"; version: string; percent: number; reason: string }
  | { action: "advance"; percent: number; reason: string }
  | { action: "pause"; reason: string }
  | { action: "hold"; reason: string }

/** Parse stored guardrails, falling back to the defaults field by field. */
export function readGuardrails(stored: unknown): Guardrails {
  const value = stored && typeof stored === "object" ? (stored as Partial<Guardrails>) : {}
  const steps = Array.isArray(value.steps) && value.steps.every((s) => Number.isInteger(s) && s > 0 && s <= 100)
    ? [...new Set(value.steps)].sort((a, b) => a - b)
    : DEFAULT_GUARDRAILS.steps
  return {
    enabled: value.enabled === true,
    steps: steps.at(-1) === 100 ? steps : [...steps, 100],
    hours: typeof value.hours === "number" && value.hours >= 1 && value.hours <= 24 * 14 ? value.hours : DEFAULT_GUARDRAILS.hours,
    minMacs: typeof value.minMacs === "number" && value.minMacs >= LEAST_MACS && value.minMacs <= 10_000 ? Math.floor(value.minMacs) : DEFAULT_GUARDRAILS.minMacs,
    startBefore: typeof value.startBefore === "number" && value.startBefore > 0 && value.startBefore <= 100 ? value.startBefore : undefined,
  }
}

/**
 * What to do with the newest release now. A release the rollout doesn't
 * name yet is adopted at the first step; a failing one is paused; a healthy
 * one that has had its time, and enough Macs, moves to the next step.
 * Anything done by hand (a pause, a pull) is left alone.
 */
export function decide(
  config: Guardrails,
  rollout: RolloutState,
  newest: string | undefined,
  health: { verdict: "early" | "healthy" | "watch" | "failing"; reasons: string[]; macs: number },
  now: Date,
): Decision {
  if (!config.enabled) return { action: "hold", reason: "Guardrails are off" }
  if (!newest) return { action: "hold", reason: "No release" }
  if (rollout.pulled.includes(newest)) return { action: "hold", reason: `${newest} is pulled` }
  if (rollout.version !== newest) {
    return { action: "adopt", version: newest, percent: config.steps[0], reason: `${newest} starts at ${config.steps[0]}%` }
  }
  if (rollout.paused) return { action: "hold", reason: rollout.pausedBy === "guardrail" ? "Paused by a guardrail; resume by hand once it's fixed" : "Paused by hand" }
  if (health.verdict === "failing") {
    return rollout.resumedByHand === newest
      ? { action: "hold", reason: `Resumed by hand while failing (${health.reasons[0] ?? "failing"}); not moving it on` }
      : { action: "pause", reason: health.reasons[0] ?? "Failing" }
  }
  if (rollout.percent >= 100) return { action: "hold", reason: "Out to everyone" }
  // Anything wrong reported, even on too few Macs for a verdict, holds it.
  if (health.reasons.length) return { action: "hold", reason: `Holding at ${rollout.percent}%: ${health.reasons[0]}` }
  const since = rollout.changedAt ? (now.getTime() - Date.parse(rollout.changedAt)) / 3_600_000 : Infinity
  if (since < config.hours) return { action: "hold", reason: `At ${rollout.percent}% for ${Math.floor(since)} of ${config.hours} hours` }
  const next = config.steps.find((s) => s > rollout.percent) ?? 100
  if (health.macs < config.minMacs) {
    return since >= config.hours * QUIET_STEPS
      ? { action: "advance", percent: next, reason: `Nothing wrong reported in ${Math.floor(since)} hours (${health.macs} Macs reporting)` }
      : { action: "hold", reason: `Waiting for ${config.minMacs} Macs to report (${health.macs} so far), or ${config.hours * QUIET_STEPS} quiet hours` }
  }
  return { action: "advance", percent: next, reason: `Healthy on ${health.macs} Macs after ${Math.floor(since)} hours` }
}
