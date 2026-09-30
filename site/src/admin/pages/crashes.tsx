import { useState } from "react"
import { Check, ChevronDown, Copy } from "lucide-react"
import type { CrashGroup, Crashes } from "../../../worker/mission-types"
import { useApi } from "../api"
import { Spark } from "../charts"
import { ago, number, percent, plural } from "../format"
import type { PageProps } from "../main"
import { Card, Empty, Loading, PageHead, Problem, Table, Tag } from "../ui"

/** Each binary's debug symbols, as `make app` keeps them. */
const SYMBOLS: Record<string, string> = {
  Parallex: "ParallexApp.dSYM",
  parallex: "parallex.dSYM",
  "parallex-launcher": "parallex-launcher.dSYM",
  "parallex-router": "parallex-router.dSYM",
  "parallex-web": "parallex-web.dSYM",
  "libparallexhome.dylib": "libparallexhome.dylib.dSYM",
  "libparallexgroups.dylib": "libparallexgroups.dylib.dSYM",
}

export function CrashesPage({ days }: PageProps) {
  const { data, error } = useApi<Crashes>("crashes", days)
  const [open, setOpen] = useState<string | null>(null)
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />
  return (
    <>
      <PageHead
        title="Crashes"
        note="Parallex's own crashes and hangs, grouped by where in its code they happened. Frames outside Parallex never leave the Mac."
      />
      <Card title="Crash-free Macs by version" note={`Last ${days} days.`} flush>
        <Table
          head={["Version", "Macs", "Crashed", "Crash-free"]}
          rows={data.crashFree.map((v) => [
            <span className="font-medium">{v.version}</span>,
            number(v.macs),
            number(v.crashed),
            <span className={v.macs && v.crashed / v.macs > 0.01 ? "font-medium text-brand" : "text-good"}>{v.macs ? percent(1 - v.crashed / v.macs, 1) : "–"}</span>,
          ])}
          empty="No reports yet."
        />
      </Card>
      <Card title="Groups" note="Most Macs first. Open one for its frames and how to read them." flush>
        {data.groups.length === 0 ? (
          <div className="px-5 pb-5"><Empty>No crashes or hangs reported in this window.</Empty></div>
        ) : (
          <ul>
            {data.groups.map((group) => (
              <CrashRow key={group.signature} group={group} open={open === group.signature} toggle={() => setOpen(open === group.signature ? null : group.signature)} />
            ))}
          </ul>
        )}
      </Card>
    </>
  )
}

function CrashRow({ group, open, toggle }: { group: CrashGroup; open: boolean; toggle: () => void }) {
  return (
    <li className="border-t">
      <button onClick={toggle} aria-expanded={open} className="grid w-full grid-cols-[minmax(0,1fr)_auto] items-center gap-4 px-5 py-3 text-left hover:bg-raised md:grid-cols-[minmax(0,1fr)_120px_140px_20px]">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <Tag tone={group.kind === "crash" ? "brand" : "caution"}>{group.kind === "crash" ? "Crash" : "Hang"}</Tag>
            <span className="truncate font-medium">{group.summary}</span>
          </div>
          <div className="mt-0.5 text-[12px] text-muted">
            {plural(group.macs, "Mac")}, {plural(group.total, "time")}; first seen {ago(group.firstDay)} in {group.firstVersion}, last {ago(group.lastDay)} in {group.lastVersion}
          </div>
        </div>
        <div className="hidden md:block"><Spark values={group.days} /></div>
        <div className="hidden flex-wrap justify-end gap-1 md:flex">{group.versions.slice(0, 3).map((v) => <Tag key={v.name}>{v.name}</Tag>)}</div>
        <ChevronDown className={`size-4 text-muted transition-transform ${open ? "rotate-180" : ""}`} />
      </button>
      {open && <CrashDetail group={group} />}
    </li>
  )
}

function CrashDetail({ group }: { group: CrashGroup }) {
  const version = group.lastVersion
  const commands = [...new Set(group.frames.map((f) => f.binary))].map((binary) => {
    const offsets = group.frames.filter((f) => f.binary === binary).map((f) => `0x${(0x100000000 + f.offset).toString(16)}`)
    return `atos -arch arm64 -o dist/symbols/${version}/${SYMBOLS[binary] ?? `${binary}.dSYM`} -l 0x100000000 ${offsets.join(" ")}`
  })
  return (
    <div className="grid gap-4 bg-raised px-5 pt-1 pb-5">
      <div className="overflow-x-auto rounded-xl border bg-surface">
        <table className="w-full min-w-[520px] font-mono text-[12px]">
          <tbody>
            {group.frames.map((frame, i) => (
              <tr key={i} className="border-b last:border-b-0">
                <td className="w-8 px-3 py-1.5 text-faint">{i}</td>
                <td className="px-3 py-1.5">{frame.binary}</td>
                <td className="px-3 py-1.5 text-right">+0x{frame.offset.toString(16)}</td>
                <td className="px-3 py-1.5 text-right text-faint">{frame.uuid}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="grid gap-2">
        <div className="text-[12.5px] text-muted">
          To name the functions, from the repository with {version}'s symbols (kept by <code className="font-mono">make app</code>); use <code className="font-mono">-arch x86_64</code> on Intel. Check a binary's UUID with <code className="font-mono">dwarfdump --uuid</code>.
        </div>
        {commands.map((command) => <CopyLine key={command} text={command} />)}
      </div>
      <div className="text-[12px] text-faint">Signature {group.signature}</div>
    </div>
  )
}

function CopyLine({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <div className="flex items-center gap-2 rounded-xl border bg-surface pl-3">
      <code className="min-w-0 flex-1 overflow-x-auto py-2 font-mono text-[12px] whitespace-nowrap">{text}</code>
      <button
        aria-label="Copy"
        onClick={() => navigator.clipboard.writeText(text).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1500) })}
        className="grid size-8 shrink-0 place-items-center text-muted hover:text-ink [&_svg]:size-3.5"
      >
        {copied ? <Check /> : <Copy />}
      </button>
    </div>
  )
}
