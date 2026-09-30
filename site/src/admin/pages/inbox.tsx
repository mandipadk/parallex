import { useState } from "react"
import type { Inbox } from "../../../worker/mission-types"
import { post, useApi } from "../api"
import { ago, appLabel, number } from "../format"
import { draftNotice, type PageProps } from "../main"
import { Button, Card, Empty, Loading, PageHead, Problem, Segmented, Tag } from "../ui"

type Filter = "open" | "done" | "all"
type Note = Inbox["notes"][number]

const FACT_LABELS: Record<string, (value: unknown) => string> = {
  framework: (v) => String(v),
  quitsAtLaunch: (v) => `quit at launch ${number(Number(v))} ${Number(v) === 1 ? "time" : "times"}`,
  isolation: (v) => (v === "clean" ? "isolation check clean" : v === "leak" ? "isolation check found something" : "isolation not checked"),
  running: (v) => (v ? "running" : "not running"),
  guard: (v) => (v ? "Guard on" : "Guard off"),
  separateKeychain: (v) => (v ? "own keychain" : "shared keychain"),
  pinnedVersion: (v) => (v ? "on a pinned version" : ""),
  sharesSettings: (v) => (v ? "shares settings" : ""),
  problems: (v) => (Array.isArray(v) && v.length ? `needs: ${v.join(", ")}` : ""),
}

export function InboxPage({ days }: PageProps) {
  const { data, error, reload } = useApi<Inbox>("inbox", days)
  const [filter, setFilter] = useState<Filter>("open")
  const [busy, setBusy] = useState(false)
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />

  const act = async (id: number, action: string, confirmText?: string) => {
    if (confirmText && !confirm(confirmText)) return
    setBusy(true)
    try {
      await post("feedback", { id, action })
      reload()
    } finally {
      setBusy(false)
    }
  }
  const shown = data.notes.filter((n) => (filter === "all" ? true : filter === "done" ? n.status === "done" : n.status !== "done"))
  const open = (data.counts.new ?? 0) + (data.counts.seen ?? 0)

  return (
    <>
      <PageHead
        title="Inbox"
        note="What people send from Parallex › Something's Off, with what the app attached (they see it first). A reply address is there only if they typed one, and it's deleted when a note is done, or after 90 days."
        actions={
          <Segmented label="Show" value={filter} onChange={setFilter}
            options={[{ value: "open", label: `Open ${open}` }, { value: "done", label: "Done" }, { value: "all", label: "All" }]} />
        }
      />
      {shown.length === 0 ? (
        <Card><Empty>{filter === "open" ? "Nothing waiting." : "Nothing here."}</Empty></Card>
      ) : (
        <div className="grid gap-3">
          {shown.map((note) => <NoteCard key={note.id} note={note} busy={busy} act={act} />)}
        </div>
      )}
    </>
  )
}

function NoteCard({ note, busy, act }: { note: Note; busy: boolean; act: (id: number, action: string, confirmText?: string) => Promise<void> }) {
  const facts = Object.entries(note.facts).map(([key, value]) => FACT_LABELS[key]?.(value) ?? "").filter(Boolean)
  const app = note.app && note.app !== "other" ? appLabel(null, note.app) : note.app === "other" ? "an app that isn't well-known" : null
  return (
    <section className={`rounded-2xl border bg-surface px-5 py-4 ${note.status === "new" ? "border-brand/40" : ""}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2 text-[12.5px] text-muted">
          {note.status === "new" && <Tag tone="brand">New</Tag>}
          {note.status === "done" && <Tag tone="good">Done</Tag>}
          <span>#{note.id}, {ago(note.at.slice(0, 10))}</span>
          <span>Parallex {note.version} on macOS {note.os}, {note.arch === "arm64" ? "Apple silicon" : note.arch === "x86_64" ? "Intel" : note.arch}</span>
        </div>
        <div className="flex flex-wrap gap-2">
          {note.app && note.app !== "other" && (
            <Button disabled={busy} onClick={() => draftNotice({
              bundle: note.app!, name: appLabel(null, note.app!), versions: note.appVersion ?? "*",
              message: "", source: `feedback:${note.id}`,
            })}>Draft a notice</Button>
          )}
          {note.status === "done"
            ? <Button disabled={busy} onClick={() => act(note.id, "reopen")}>Reopen</Button>
            : <Button tone="current" disabled={busy} onClick={() => act(note.id, "done", note.contact ? "Mark done? The reply address is deleted with it." : undefined)}>Done</Button>}
          <Button tone="danger" disabled={busy} onClick={() => act(note.id, "delete", "Delete this note for good?")}>Delete</Button>
        </div>
      </div>
      <p className="mt-3 text-[14px] leading-relaxed whitespace-pre-wrap">{note.message}</p>
      {(app || facts.length > 0 || note.contact) && (
        <div className="mt-3 grid gap-1 text-[12.5px] text-muted">
          {app && <span>About a {note.kind ?? "instance"} of {app}{note.appVersion ? ` ${note.appVersion}` : ""}{facts.length ? `: ${facts.join(", ")}` : ""}</span>}
          {note.contact && <span>Reply to <a className="text-ink underline decoration-rule underline-offset-2" href={`mailto:${note.contact}?subject=${encodeURIComponent("Your note about Parallex")}`}>{note.contact}</a></span>}
        </div>
      )}
    </section>
  )
}
