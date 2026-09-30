import { useCallback, useEffect, useState } from "react"

/** Mission Control's API; signed-out answers send you to sign in. */
export async function get<T>(path: string, days: number): Promise<T> {
  const response = await fetch(`/admin/api/${path}?days=${days}`, { headers: { Accept: "application/json" }, credentials: "same-origin" })
  if (response.status === 401) {
    location.reload()
    throw new Error("Signed out")
  }
  if (!response.ok) throw new Error(`${path} answered ${response.status}`)
  return (await response.json()) as T
}

/** An action, as the forms post it. */
export async function post(path: string, fields: Record<string, string | number>): Promise<void> {
  const body = new FormData()
  for (const [key, value] of Object.entries(fields)) body.set(key, String(value))
  const response = await fetch(`/admin/${path}`, { method: "POST", body, headers: { Accept: "application/json" }, credentials: "same-origin" })
  if (!response.ok) throw new Error(`That didn't work (${response.status}).`)
}

export type Loaded<T> = { data: T | null; error: string | null; loading: boolean; reload: () => void }

/** An API answer for this window, refreshed every few minutes. */
export function useApi<T>(path: string, days: number): Loaded<T> {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [tick, setTick] = useState(0)
  const reload = useCallback(() => setTick((t) => t + 1), [])
  useEffect(() => {
    let current = true
    setLoading(true)
    get<T>(path, days)
      .then((answer) => {
        if (!current) return
        setData(answer)
        setError(null)
      })
      .catch((problem: unknown) => current && setError(problem instanceof Error ? problem.message : String(problem)))
      .finally(() => current && setLoading(false))
    return () => {
      current = false
    }
  }, [path, days, tick])
  useEffect(() => {
    const timer = setInterval(reload, 5 * 60_000)
    return () => clearInterval(timer)
  }, [reload])
  return { data, error, loading, reload }
}
