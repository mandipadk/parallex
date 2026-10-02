/** The compatibility lab's latest run (the Compatibility lab workflow
 * publishes it to the repository's lab-results branch every night). */
export const LAB_URL = "https://raw.githubusercontent.com/mandipadk/parallex/lab-results/compat-lab.json"

export type LabCounts = { processes?: number; leaks?: number; blocked?: number; crashes?: number }

/** One app's night: its default instance (a copy, or for browsers a wrapper
 * with a profile folder of its own; runs before modes were recorded only
 * made copies) and, for a wrapper, an own-identity copy too. */
export type LabApp = LabCounts & {
  app: string
  version?: string
  mode?: "copy" | "wrapper"
  result: string
  ownIdentity?: LabCounts & { result: string }
}

/** How the default instance was made: copies unless the run says otherwise. */
export const labMode = (app: { mode?: string }): "copy" | "wrapper" => (app.mode === "wrapper" ? "wrapper" : "copy")

export type LabRun = { date: string; macos: string; parallex: string; apps: LabApp[] }

/** Only what the page shows, checked: anything else in the file is ignored. */
export function parseLab(body: unknown): LabRun | null {
  if (typeof body !== "object" || body === null) return null
  const run = body as Record<string, unknown>
  if (typeof run.date !== "string" || !Array.isArray(run.apps)) return null
  const text = (value: unknown, max = 80) => (typeof value === "string" ? value.slice(0, max) : undefined)
  const count = (value: unknown) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined)
  const apps: LabApp[] = []
  for (const entry of run.apps.slice(0, 100)) {
    if (typeof entry !== "object" || entry === null) continue
    const app = entry as Record<string, unknown>
    const name = text(app.app)
    const result = text(app.result, 20)
    if (!name || !result) continue
    const counts = (from: Record<string, unknown>): LabCounts => ({
      processes: count(from.processes), leaks: count(from.leaks), blocked: count(from.blocked), crashes: count(from.crashes),
    })
    const parsed: LabApp = { app: name, version: text(app.version, 40), result, ...counts(app) }
    if (app.mode === "copy" || app.mode === "wrapper") parsed.mode = app.mode
    const own = app.ownIdentity
    if (typeof own === "object" && own !== null) {
      const ownResult = text((own as Record<string, unknown>).result, 20)
      if (ownResult) parsed.ownIdentity = { result: ownResult, ...counts(own as Record<string, unknown>) }
    }
    apps.push(parsed)
  }
  return { date: run.date.slice(0, 30), macos: text(run.macos, 20) ?? "", parallex: text(run.parallex, 20) ?? "", apps }
}

export async function latestLab(): Promise<LabRun | null> {
  try {
    // Keyed by the hour, so no answer (a missing file, say) outlives it.
    const response = await fetch(`${LAB_URL}?hour=${Math.floor(Date.now() / 3_600_000)}`, {
      // An hour for the results; a minute for anything else (the branch
      // missing, say), so it's picked up soon after it appears.
      cf: { cacheTtlByStatus: { "200-299": 3600, "400-599": 60 }, cacheEverything: true },
      signal: AbortSignal.timeout(3000),
    } as RequestInit)
    if (!response.ok) return null
    return parseLab(await response.json())
  } catch {
    return null
  }
}
