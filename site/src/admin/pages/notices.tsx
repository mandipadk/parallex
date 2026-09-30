import { useEffect, useState } from "react"
import type { Notices } from "../../../worker/mission-types"
import { post, useApi } from "../api"
import { ago, appLabel } from "../format"
import type { DraftSeed, PageProps } from "../main"
import { Button, Card, Empty, Loading, PageHead, Problem, Segmented, Tag } from "../ui"

type Form = { id: number; bundle: string; name: string; versions: string; level: "warning" | "unsupported"; message: string; website: string; source: string }
const blank: Form = { id: 0, bundle: "", name: "", versions: "", level: "warning", message: "", website: "", source: "" }

/** A draft handed over from Apps or the Inbox, once. */
function seedFromHash(): Form | null {
  let raw: string | null = null
  try {
    raw = sessionStorage.getItem("mc-draft")
    sessionStorage.removeItem("mc-draft")
  } catch {
    raw = null
  }
  if (!raw) return null
  try {
    const seed = JSON.parse(raw) as DraftSeed
    return {
      ...blank, bundle: seed.bundle, name: seed.name, versions: seed.versions, source: seed.source,
      message: seed.message || `Copies of ${seed.name}${seed.versions && seed.versions !== "*" ? ` ${seed.versions}` : ""} quit at launch. Parallex is looking into it.`,
    }
  } catch {
    return null
  }
}

const field = "h-9 w-full rounded-xl border bg-ground px-3 text-[13px] outline-none focus:border-faint"

export function NoticesPage({ days }: PageProps) {
  const { data, error, reload } = useApi<Notices>("notices", days)
  const [form, setForm] = useState<Form | null>(seedFromHash)
  const [busy, setBusy] = useState(false)
  const [problem, setProblem] = useState<string | null>(null)
  useEffect(() => {
    const follow = () => { const seed = seedFromHash(); if (seed) setForm(seed) }
    addEventListener("mc-draft", follow)
    return () => removeEventListener("mc-draft", follow)
  }, [])
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />

  const send = async (fields: Record<string, string | number>) => {
    setBusy(true)
    setProblem(null)
    try {
      await post("notice", fields)
      setForm(null)
      reload()
    } catch (reason) {
      setProblem(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy(false)
    }
  }
  const save = (action: "save" | "ready") => form && send({ ...form, action })
  const ready = data.drafts.filter((d) => d.status === "ready").length

  return (
    <>
      <PageHead
        title="Notices"
        note={<>What Parallex shows about an app whose copies misbehave, without an update of its own. Draft here; <code className="font-mono">make notices</code> on the release Mac signs the ready ones and publishes them.</>}
        actions={!form && <Button tone="primary" onClick={() => setForm({ ...blank })}>New notice</Button>}
      />

      {form && (
        <Card title={form.id ? "Edit notice" : "New notice"} note={form.source.startsWith("feedback:") ? `From note #${form.source.slice(9)}` : form.source === "apps" ? "From a flagged app version" : undefined}>
          <div className="grid gap-3">
            <div className="grid gap-3 md:grid-cols-3">
              <label className="grid gap-1 text-[12.5px] text-muted">App name
                <input className={field} value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Telegram" />
              </label>
              <label className="grid gap-1 text-[12.5px] text-muted">Bundle ID
                <input className={`${field} font-mono`} value={form.bundle} onChange={(e) => setForm({ ...form, bundle: e.target.value })} placeholder="ru.keepcoder.Telegram" />
              </label>
              <label className="grid gap-1 text-[12.5px] text-muted">App versions
                <input className={`${field} font-mono`} value={form.versions} onChange={(e) => setForm({ ...form, versions: e.target.value })} placeholder="11.5, >=11.5, 11.4...11.6, or *" />
              </label>
            </div>
            <label className="grid gap-1 text-[12.5px] text-muted">What people see
              <textarea className={`${field} h-20 py-2 leading-relaxed`} value={form.message} maxLength={400} onChange={(e) => setForm({ ...form, message: e.target.value })} />
            </label>
            <div className="grid gap-3 md:grid-cols-[auto_minmax(0,1fr)] md:items-end">
              <div className="grid gap-1 text-[12.5px] text-muted">How bad
                <Segmented label="How bad" value={form.level} onChange={(level) => setForm({ ...form, level })}
                  options={[{ value: "warning", label: "Copies have trouble" }, { value: "unsupported", label: "Copies don't work" }]} />
              </div>
              <label className="grid gap-1 text-[12.5px] text-muted">Website to offer instead (optional)
                <input className={field} value={form.website} onChange={(e) => setForm({ ...form, website: e.target.value })} placeholder="https://web.telegram.org" />
              </label>
            </div>
            {problem && <p className="text-[12.5px] text-brand">{problem}</p>}
            <div className="flex flex-wrap justify-end gap-2">
              <Button disabled={busy} onClick={() => { setForm(null); setProblem(null) }}>Cancel</Button>
              <Button disabled={busy} onClick={() => save("save")}>Save draft</Button>
              <Button tone="primary" disabled={busy} onClick={() => save("ready")}>Ready to publish</Button>
            </div>
          </div>
        </Card>
      )}

      <Card title="Drafts" note={ready
        ? <>{ready} ready: publish with <code className="font-mono">make notices</code>, which signs them with the release key and deploys the site.</>
        : <>Ready ones are published by <code className="font-mono">make notices</code> on the release Mac.</>} flush>
        {data.drafts.length === 0 ? <div className="px-5 pb-5"><Empty>No drafts yet. Flagged app versions and notes about an app have a Draft a notice button.</Empty></div> : (
          <ul>
            {data.drafts.map((d) => (
              <li key={d.id} className="flex flex-wrap items-start justify-between gap-3 border-t px-5 py-3 text-[13px]">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-medium">{d.name} {d.versions !== "*" && <span className="text-muted">{d.versions}</span>}</span>
                    <Tag tone={d.status === "ready" ? "brand" : d.status === "published" ? "good" : "plain"}>
                      {d.status === "ready" ? "Ready to publish" : d.status === "published" ? `Published ${d.published ? ago(d.published.slice(0, 10)) : ""}` : "Draft"}
                    </Tag>
                    <Tag tone={d.level === "unsupported" ? "brand" : "caution"}>{d.level === "unsupported" ? "Copies don't work" : "Copies have trouble"}</Tag>
                  </div>
                  <p className="mt-1 text-muted">{d.message}</p>
                </div>
                {d.status !== "published" && (
                  <div className="flex gap-2">
                    <Button disabled={busy} onClick={() => setForm({
                      id: d.id, bundle: d.bundleID, name: d.name, versions: d.versions, level: d.level, message: d.message, website: d.website ?? "", source: d.source,
                    })}>Edit</Button>
                    {d.status === "ready" && <Button disabled={busy} onClick={() => send({ id: d.id, action: "unready" })}>Not yet</Button>}
                    <Button tone="danger" disabled={busy} onClick={() => confirm("Delete this draft?") && send({ id: d.id, action: "delete" })}>Delete</Button>
                  </div>
                )}
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card title="Shown now" note={data.issued ? `The signed file Parallex reads, issued ${ago(data.issued.slice(0, 10))}.` : "The signed file Parallex reads."}>
        {data.live.length === 0 ? <Empty>No app notices out.</Empty> : (
          <ul className="grid gap-2 text-[13px]">
            {data.live.map((n, i) => (
              <li key={i}>
                <span className="font-medium">{appLabel(null, n.bundleID)}</span> <span className="text-muted">{n.versions ?? "all versions"}: {n.message}</span>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </>
  )
}
