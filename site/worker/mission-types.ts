/**
 * What Mission Control's API answers (worker/mission.ts), shared with the
 * dashboard (src/admin). Types only.
 */
import type { Health, Cohort } from "./health"

export type Named = { name: string; count: number }
export type Day = { day: string; [series: string]: number | string }

export interface Overview {
  generated: string
  /** From update checks: every Mac with automatic checks on. */
  active: { day: number; week: number; month: number }
  newThisWeek: number
  /** From usage reports: Macs that share, counted once each. */
  sharing: { day: number; week: number; month: number; newThisWeek: number }
  /** Every day of the window: checks, new Macs, sharing Macs, crashes. */
  series: { day: string; active: number; fresh: number; sharing: number; crashes: number }[]
  latest: { version: string; health: Health; macs: number; adoption: number } | null
  alerts: Alert[]
  totals: { instances: number; copies: number; web: number; created: number; snapshots: number }
}

export interface Alert {
  level: "failing" | "watch"
  title: string
  detail: string
  /** Where to look: a tab of the dashboard. */
  tab: "releases" | "crashes" | "apps" | "growth"
}

export interface ReleaseRow {
  version: string
  published: boolean
  /** Macs that reported from it in the window, and on update checks today. */
  macs: number
  checksToday: number
  health: Health
  counts: {
    created: [number, number]
    refreshed: [number, number]
    updated: [number, number]
    opened: [number, number]
    leaks: [number, number]
    hangs: number
    crashedMacs: number
  }
}

export interface Releases {
  rollout: { version: string; percent: number; paused: boolean; pulled: string[]; startPercent: number }
  published: string[]
  releases: ReleaseRow[]
  /** Adoption: Macs on each version, per day. */
  adoption: { day: string; versions: Record<string, number> }[]
  downloads: { tag: string; downloads: number }[]
  updateSteps: Named[]
}

export interface CrashGroup {
  signature: string
  kind: "crash" | "hang"
  summary: string
  frames: { binary: string; uuid: string; offset: number }[]
  firstDay: string
  lastDay: string
  firstVersion: string
  lastVersion: string
  macs: number
  total: number
  versions: Named[]
  days: number[]
}

export interface Crashes {
  days: string[]
  groups: CrashGroup[]
  /** Crash-free Macs per version in the window. */
  crashFree: { version: string; macs: number; crashed: number }[]
}

export interface AppRow {
  app: string
  name: string | null
  listed: boolean
  macs: number
  instances: number
  kinds: Named[]
  versions: { version: string; macs: number; ran: number; quit: number; refreshFailed: number; leaks: number }[]
  ran: number
  quit: number
  created: [number, number]
  refreshed: [number, number]
  leaks: [number, number]
  /** A version's copies quit at launch on two or more Macs, and on at
   *  least a third of its starts. */
  flagged: boolean
  flaggedVersions: string[]
}

export interface Apps {
  apps: AppRow[]
  other: { macs: number; apps: number }
  websites: Named[]
  otherWebsites: number
  frameworks: { framework: string; ok: number; failed: number }[]
  createSteps: Named[]
}

export interface Growth {
  funnel: { step: string; label: string; macs: number }[]
  onboarding: Named[]
  cohorts: Cohort[]
  features: { feature: string; macs: number; share: number }[]
  commands: Named[]
  platforms: { os: Named[]; arch: Named[]; version: Named[] }
  sources: Named[]
}

export interface Community {
  reports: { issue: number; url: string; title: string; name: string | null; bundleID: string | null; version: string | null; verdict: string | null; approved: boolean }[]
  listed: { bundle: string; name: string }[]
  stats: Record<string, number>
  donations: { kofiCents: number; kofiCount: number; otherCurrencies: string[]; recent: { kind: string; cents: number; currency: string; at: string }[] }
  log: { at: string; action: string; detail: string }[]
}
