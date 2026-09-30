/** The compatibility lab's latest run (the Compatibility lab workflow
 * publishes it to the repository's lab-results branch every night). */
export const LAB_URL = "https://raw.githubusercontent.com/mandipadk/parallex/lab-results/compat-lab.json"

export type LabApp = {
  app: string
  version?: string
  result: string
  processes?: number
  leaks?: number
  blocked?: number
  crashes?: number
}

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
    apps.push({
      app: name, version: text(app.version, 40), result,
      processes: count(app.processes), leaks: count(app.leaks), blocked: count(app.blocked), crashes: count(app.crashes),
    })
  }
  return { date: run.date.slice(0, 30), macos: text(run.macos, 20) ?? "", parallex: text(run.parallex, 20) ?? "", apps }
}

export async function latestLab(): Promise<LabRun | null> {
  try {
    const response = await fetch(LAB_URL, {
      cf: { cacheTtl: 3600, cacheEverything: true },
      signal: AbortSignal.timeout(3000),
    } as RequestInit)
    if (!response.ok) return null
    return parseLab(await response.json())
  } catch {
    return null
  }
}
