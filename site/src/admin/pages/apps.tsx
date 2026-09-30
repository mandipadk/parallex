import { useState } from "react"
import { ChevronDown } from "lucide-react"
import type { AppRow, Apps } from "../../../worker/mission-types"
import { post, useApi } from "../api"
import { appLabel, number, percent, plural, rate } from "../format"
import type { PageProps } from "../main"
import { Bars, Button, Card, Empty, Loading, PageHead, Problem, Tag } from "../ui"

export function AppsPage({ days }: PageProps) {
  const { data, error, reload } = useApi<Apps>("apps", days)
  const [open, setOpen] = useState<string | null>(null)
  const [query, setQuery] = useState("")
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />
  const shown = data.apps.filter((a) => !query || `${a.name ?? ""} ${a.app}`.toLowerCase().includes(query.toLowerCase()))
  const flagged = data.apps.filter((a) => a.flagged).length

  return (
    <>
      <PageHead
        title="Apps"
        note="Which well-known apps people copy, on which versions, and how those copies do. Apps that aren't well-known are only counted."
        actions={
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Find an app"
            aria-label="Find an app"
            className="h-9 w-56 rounded-full border bg-surface px-4 text-[13px] outline-none placeholder:text-faint focus:border-faint"
          />
        }
      />
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        <Small label="Well-known apps" value={number(data.apps.length)} />
        <Small label="Needing a look" value={number(flagged)} tone={flagged ? "brand" : undefined} />
        <Small label="Other apps" value={number(data.other.apps)} note={plural(data.other.macs, "Mac")} />
        <Small label="Website presets" value={number(data.websites.length)} note={`${number(data.otherWebsites)} other sites`} />
      </div>

      <Card title="Compatibility" note={`Last ${days} days. An app version whose copies quit at launch on two or more Macs, and on a third of starts, is flagged.`} flush>
        {shown.length === 0 ? <div className="px-5 pb-5"><Empty>No apps reported yet.</Empty></div> : (
          <div className="overflow-x-auto">
            <div className="min-w-[720px]">
              <div className="grid grid-cols-[minmax(0,1.6fr)_repeat(5,minmax(0,1fr))_20px] gap-3 border-b px-5 pb-2 text-[12px] font-medium text-muted">
                <span>App</span><span className="text-right">Macs</span><span className="text-right">Instances</span><span className="text-right">Quit at launch</span><span className="text-right">Refresh failures</span><span className="text-right">Leaks found</span><span />
              </div>
              <ul>
                {shown.map((app) => <AppLine key={app.app} app={app} open={open === app.app} toggle={() => setOpen(open === app.app ? null : app.app)} onChange={reload} />)}
              </ul>
            </div>
          </div>
        )}
      </Card>

      <div className="grid gap-4 lg:grid-cols-3">
        <Card title="Making instances, by framework" note="Failures out of attempts.">
          {data.frameworks.length === 0 ? <Empty>Nothing yet.</Empty> : (
            <Bars items={data.frameworks.map((f) => ({ name: f.framework, count: f.ok + f.failed, hint: f.failed ? `${percent(f.failed / (f.ok + f.failed))} failed` : undefined }))} />
          )}
        </Card>
        <Card title="Where making one fails" note="The step it stopped at.">
          <Bars items={data.createSteps} empty="No failures." />
        </Card>
        <Card title="Website presets" note="Macs with a web instance of each.">
          <Bars items={data.websites} empty="None yet." />
        </Card>
      </div>
    </>
  )
}

function Small({ label, value, note, tone }: { label: string; value: string; note?: string; tone?: "brand" }) {
  return (
    <div className="rounded-2xl border bg-surface px-5 py-3.5">
      <div className="text-[12.5px] text-muted">{label}</div>
      <div className={`tabular text-[22px] font-semibold tracking-tight ${tone === "brand" ? "text-brand" : ""}`}>{value}</div>
      {note && <div className="text-[12px] text-faint">{note}</div>}
    </div>
  )
}

function Cell({ pair, danger }: { pair: [number, number]; danger: number }) {
  const r = rate(pair)
  if (r === null) return <span className="text-right text-faint">–</span>
  return <span className={`text-right ${r >= danger ? "font-medium text-brand" : ""}`} title={`${number(pair[1])} of ${number(pair[0] + pair[1])}`}>{percent(r)}</span>
}

function AppLine({ app, open, toggle, onChange }: { app: AppRow; open: boolean; toggle: () => void; onChange: () => void }) {
  const [busy, setBusy] = useState(false)
  const list = async (action: "add" | "remove") => {
    const name = action === "add" ? prompt("Name it as it should appear on the public compatibility list:", app.name ?? appLabel(null, app.app)) : ""
    if (action === "add" && !name) return
    setBusy(true)
    try {
      await post("list", { action, bundle: app.app, name: name ?? "" })
      onChange()
    } finally {
      setBusy(false)
    }
  }
  return (
    <li className="border-b last:border-b-0">
      <button onClick={toggle} aria-expanded={open} className="tabular grid w-full grid-cols-[minmax(0,1.6fr)_repeat(5,minmax(0,1fr))_20px] items-center gap-3 px-5 py-2.5 text-left text-[13px] hover:bg-raised">
        <span className="flex min-w-0 items-center gap-2">
          <span className="truncate font-medium">{appLabel(app.name, app.app)}</span>
          {app.flagged && <Tag tone="brand">{app.flaggedVersions.length ? `${app.flaggedVersions.join(", ")} quitting at launch` : "Quitting at launch"}</Tag>}
          {app.listed && <Tag tone="good">Listed</Tag>}
        </span>
        <span className="text-right">{number(app.macs)}</span>
        <span className="text-right">{number(app.instances)}</span>
        <Cell pair={[app.ran, app.quit]} danger={0.15} />
        <Cell pair={app.refreshed} danger={0.1} />
        <Cell pair={app.leaks} danger={0.2} />
        <ChevronDown className={`size-4 text-muted transition-transform ${open ? "rotate-180" : ""}`} />
      </button>
      {open && (
        <div className="grid gap-4 bg-raised px-5 pt-1 pb-4 text-[12.5px]">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <span className="text-muted">
              <code className="font-mono">{app.app}</code>
              {app.kinds.length > 0 && <>; {app.kinds.map((k) => `${number(k.count)} ${k.name}`).join(", ")}</>}
              {(app.created[0] + app.created[1]) > 0 && <>; {number(app.created[0])} made, {number(app.created[1])} failed</>}
            </span>
            {app.listed
              ? <Button disabled={busy} onClick={() => list("remove")}>Take off the public list</Button>
              : <Button disabled={busy} onClick={() => list("add")}>Add to the public list</Button>}
          </div>
          {app.versions.length > 0 && (
            <div className="overflow-hidden rounded-xl border bg-surface">
              <div className="grid grid-cols-[minmax(0,1fr)_repeat(4,minmax(0,1fr))] gap-3 border-b px-4 py-1.5 text-[12px] font-medium text-muted">
                <span>Version</span><span className="text-right">Macs</span><span className="text-right">Quit at launch</span><span className="text-right">Refresh failures</span><span className="text-right">Leaks</span>
              </div>
              {app.versions.slice(0, 8).map((v) => (
                <div key={v.version || "unknown"} className="tabular grid grid-cols-[minmax(0,1fr)_repeat(4,minmax(0,1fr))] gap-3 border-b px-4 py-1.5 last:border-b-0">
                  <span>{v.version || "Unknown"}</span>
                  <span className="text-right">{number(v.macs)}</span>
                  <span className={`text-right ${v.quit && v.quit * 3 >= v.ran + v.quit ? "font-medium text-brand" : ""}`}>{v.ran + v.quit ? `${number(v.quit)} of ${number(v.ran + v.quit)}` : "–"}</span>
                  <span className="text-right">{number(v.refreshFailed)}</span>
                  <span className="text-right">{number(v.leaks)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </li>
  )
}
