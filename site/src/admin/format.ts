export const number = (n: number) => n.toLocaleString("en-US")

export const percent = (x: number | null | undefined, digits?: number) => {
  if (x === null || x === undefined || !Number.isFinite(x)) return "–"
  const places = digits ?? (x > 0 && x < 0.1 ? 1 : 0)
  return `${(x * 100).toFixed(places)}%`
}

/** "1 Mac", "3 Macs". */
export const plural = (n: number, one: string, many = `${one}s`) => `${number(n)} ${n === 1 ? one : many}`

export const dollars = (cents: number) => `$${(cents / 100).toLocaleString("en-US", { maximumFractionDigits: cents % 100 ? 2 : 0 })}`

/** "Sep 30". */
export const shortDay = (day: string) =>
  new Date(`${day}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" })

/** "3 days ago", "today". */
export function ago(day: string, now = new Date()): string {
  const days = Math.round((Date.parse(now.toISOString().slice(0, 10)) - Date.parse(day)) / 86_400_000)
  if (days <= 0) return "today"
  if (days === 1) return "yesterday"
  if (days < 30) return `${days} days ago`
  return shortDay(day)
}

/** A failure rate out of [ok, failed], or nothing when nothing happened. */
export const rate = ([ok, failed]: [number, number]) => (ok + failed ? failed / (ok + failed) : null)

/** App bundle IDs read better without their reverse-domain prefix. */
export function appLabel(name: string | null, bundle: string): string {
  if (name) return name
  const last = bundle.split(".").pop() ?? bundle
  return last.charAt(0).toUpperCase() + last.slice(1)
}
