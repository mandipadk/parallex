/**
 * The notes an update shows: when a Mac is more than one release behind,
 * those of every release it hasn't had, newest first, each under its own
 * heading. Kept free of imports so it can be tested on its own.
 */

type Release = { tag_name?: unknown; body?: unknown }

const numbers = (version: string) => version.replace(/^v/, "").split(".").map((part) => Number.parseInt(part, 10) || 0)

/** Whether `a` is a later version than `b` ("1.10.0" after "1.9.2"). */
export function isLater(a: string, b: string): boolean {
  const [x, y] = [numbers(a), numbers(b)]
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) > (y[i] ?? 0)
  }
  return false
}

/** How many releases' notes at most; the rest are a link away. */
const MOST = 8

/**
 * `releases` newest first, as GitHub lists them; `offered` the one the Mac
 * gets; `current` the version it has. Returns the offered release's own
 * notes when it's the only one the Mac is missing.
 */
export function notesSince(releases: Release[], offered: Release, current: string, allReleasesURL: string): string {
  const own = typeof offered.body === "string" ? offered.body : ""
  const tag = String(offered.tag_name ?? "")
  if (!/^\d+(\.\d+)*$/.test(current.trim()) || !isLater(tag, current)) return own
  const missed = releases.filter((r) => {
    const version = String(r.tag_name ?? "")
    return version && !isLater(version, tag) && isLater(version, current)
  })
  if (missed.length <= 1) return own
  const sections = missed.slice(0, MOST).map((r) => {
    const body = typeof r.body === "string" && r.body.trim() ? r.body.trim() : "Bug fixes and improvements."
    return `## Parallex ${String(r.tag_name).replace(/^v/, "")}\n\n${body}`
  })
  if (missed.length > MOST) sections.push(`## And before that\n\n${missed.length - MOST} more releases since ${current}: ${allReleasesURL}`)
  return sections.join("\n\n")
}
