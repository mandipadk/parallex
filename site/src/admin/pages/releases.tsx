import { useState } from "react"
import type { ReleaseRow, Releases } from "../../../worker/mission-types"
import { post, useApi } from "../api"
import { StackedBars } from "../charts"
import { number, percent, plural, rate } from "../format"
import type { PageProps } from "../main"
import { Bars, Button, Card, Loading, PageHead, Problem, Table, Tag, VerdictTag } from "../ui"

const SHARES = [1, 10, 25, 50, 100]

export function ReleasesPage({ days }: PageProps) {
  const { data, error, reload } = useApi<Releases>("releases", days)
  const [busy, setBusy] = useState(false)
  const [failure, setFailure] = useState<string | null>(null)
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />

  const act = async (fields: Record<string, string | number>, confirmText?: string) => {
    if (confirmText && !confirm(confirmText)) return
    setBusy(true)
    setFailure(null)
    try {
      await post("release", fields)
      reload()
    } catch (problem) {
      setFailure(problem instanceof Error ? problem.message : String(problem))
    } finally {
      setBusy(false)
    }
  }

  const newest = data.published[0]
  const { rollout } = data
  const steered = rollout.version === newest
  const share = steered ? rollout.percent : rollout.startPercent
  const paused = steered && rollout.paused
  const pulled = newest ? rollout.pulled.includes(newest) : false
  const newestRow = data.releases.find((r) => r.version === newest)
  const versions = [...new Set(data.adoption.flatMap((d) => Object.keys(d.versions)))]
    .sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))

  return (
    <>
      <PageHead title="Releases" note="How each release is doing next to the one before it, and how far the newest has gone out." />
      {failure && <Problem>{failure}</Problem>}

      {newest && (
        <Card
          title={<span className="flex items-center gap-2.5">Rolling out {newest}{newestRow && <VerdictTag verdict={newestRow.health.verdict} />}</span>}
          note={pulled ? "Pulled: no Mac is offered it." : paused ? `Paused at ${share}%: Macs that don't have it yet are offered the release before.` : share >= 100 ? "Out to every Mac." : `Offered to ${share}% of Macs (those whose random number is under ${share}).`}
        >
          <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
            <div className="grid gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="mr-1 text-[12.5px] text-muted">Share</span>
                {SHARES.map((p) => (
                  <Button key={p} tone={p === share && !paused && !pulled ? "current" : "plain"} disabled={busy || pulled}
                    onClick={() => act({ action: "share", version: newest, percent: p }, p === 100 ? `Offer ${newest} to every Mac?` : undefined)}>
                    {p}%
                  </Button>
                ))}
                {paused
                  ? <Button tone="primary" disabled={busy} onClick={() => act({ action: "resume", version: newest })}>Resume</Button>
                  : <Button disabled={busy || pulled} onClick={() => act({ action: "pause", version: newest })}>Pause</Button>}
                {pulled
                  ? <Button disabled={busy} onClick={() => act({ action: "restore", version: newest })}>Restore</Button>
                  : <Button tone="danger" disabled={busy} onClick={() => act({ action: "pull", version: newest }, `Pull ${newest}? No Mac will be offered it; Macs that have it keep it.`)}>Pull</Button>}
              </div>
              {newestRow && newestRow.health.reasons.length > 0 && (
                <ul className="grid gap-1 text-[12.5px] text-muted">{newestRow.health.reasons.map((r) => <li key={r}>{r}</li>)}</ul>
              )}
            </div>
            <div className="flex items-center gap-2 text-[12.5px] text-muted">
              New releases start at
              {[10, 100].map((p) => (
                <Button key={p} tone={rollout.startPercent === p ? "current" : "plain"} disabled={busy}
                  onClick={() => act({ action: "start", version: newest, percent: p })}>
                  {p === 100 ? "Everyone" : `${p}%`}
                </Button>
              ))}
            </div>
          </div>
        </Card>
      )}

      <Card title="Scorecard" note={`Last ${days} days. Rates are failures out of attempts; each release is judged against the one below it.`} flush>
        <Table
          head={["Release", "Macs", "Crash-free", "Updates to it", "Instances made", "Refreshes", "Copies quitting", "Leaks found", "Verdict"]}
          rows={data.releases.map((r) => scoreRow(r, rollout.pulled.includes(r.version)))}
          empty="No usage reports yet: they start with 1.6."
        />
      </Card>

      <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_320px]">
        <Card title="Adoption" note="Macs checking for updates each day, by the version they run.">
          <StackedBars days={data.adoption.map((d) => d.day)} stacks={data.adoption.map((d) => d.versions)} keys={versions} />
        </Card>
        <div className="grid content-start gap-4">
          <Card title="Downloads" note="From GitHub, per release.">
            <Bars items={data.downloads.map((d) => ({ name: d.tag, count: d.downloads }))} limit={6} />
          </Card>
          <Card title="Where updates fail" note="The step an update stopped at.">
            <Bars items={data.updateSteps} empty="No failed updates." />
          </Card>
        </div>
      </div>
    </>
  )
}

function Rate({ pair, danger = 0.1 }: { pair: [number, number]; danger?: number }) {
  const r = rate(pair)
  if (r === null) return <span className="text-faint">–</span>
  return (
    <span title={`${number(pair[1])} of ${number(pair[0] + pair[1])}`} className={r >= danger ? "font-medium text-brand" : undefined}>
      {percent(r)}
      <span className="ml-1 text-[11.5px] text-faint">{number(pair[0] + pair[1])}</span>
    </span>
  )
}

function scoreRow(r: ReleaseRow, pulled: boolean) {
  const crashFree = r.health.crashFree
  return [
    <span className="flex items-center gap-2 font-medium">{r.version}{pulled && <Tag tone="brand">Pulled</Tag>}{!r.published && <Tag>Unreleased</Tag>}</span>,
    <span title={`${plural(r.checksToday, "Mac")} checked in on it today`}>{number(r.macs)}</span>,
    crashFree === null ? <span className="text-faint">–</span> : (
      <span className={crashFree < 0.99 ? "font-medium text-brand" : undefined} title={`${plural(r.counts.crashedMacs, "Mac")} crashed; ${number(r.counts.hangs)} hangs`}>
        {percent(crashFree, 1)}
      </span>
    ),
    <Rate pair={r.counts.updated} />,
    <Rate pair={r.counts.created} />,
    <Rate pair={r.counts.refreshed} />,
    <Rate pair={r.counts.opened} danger={0.15} />,
    <Rate pair={r.counts.leaks} danger={0.2} />,
    <VerdictTag verdict={r.health.verdict} />,
  ]
}
