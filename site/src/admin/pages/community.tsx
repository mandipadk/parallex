import { useState } from "react"
import { Download, RefreshCw } from "lucide-react"
import type { Community } from "../../../worker/mission-types"
import { post, useApi } from "../api"
import { dollars, number, shortDay } from "../format"
import type { PageProps } from "../main"
import { Button, Card, Empty, Loading, PageHead, Problem, Tag } from "../ui"

const REPO = "https://github.com/mandipadk/parallex"
const GOAL_CENTS = 9900

export function CommunityPage({ days }: PageProps) {
  const { data, error, reload } = useApi<Community>("community", days)
  const [busy, setBusy] = useState(false)
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />

  const act = async (path: string, fields: Record<string, string | number>) => {
    setBusy(true)
    try {
      await post(path, fields)
      reload()
    } finally {
      setBusy(false)
    }
  }
  const stat = (key: string) => data.stats[key] ?? 0
  const raised = data.donations.kofiCents

  return (
    <>
      <PageHead
        title="Community"
        note="Reports people file, the public compatibility list, GitHub, and donations."
        actions={<Button disabled={busy} onClick={() => act("collect", {})}><span className="flex items-center gap-1.5 [&_svg]:size-3.5"><RefreshCw />Collect now</span></Button>}
      />

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {([
          ["Stars", stat("stars"), `${REPO}/stargazers`],
          ["Downloads", stat("downloads_dmg") + stat("downloads_zip"), `${REPO}/releases`],
          ["Compatibility reports", stat("compat_reports"), `${REPO}/issues?q=label%3Acompatibility`],
          ["Open issues and PRs", stat("open_issues"), `${REPO}/issues`],
        ] as const).map(([label, value, href]) => (
          <a key={label} href={href} className="rounded-2xl border bg-surface px-5 py-3.5 hover:border-faint">
            <div className="text-[12.5px] text-muted">{label}</div>
            <div className="tabular text-[22px] font-semibold tracking-tight">{number(value)}</div>
          </a>
        ))}
      </div>

      <Card title="Compatibility reports" note="Filed on GitHub. Approving one puts its verdict on the public list, under its app." flush>
        {data.reports.length === 0 ? <div className="px-5 pb-5"><Empty>No reports yet.</Empty></div> : (
          <ul>
            {data.reports.slice(0, 30).map((r) => (
              <li key={r.issue} className="flex flex-wrap items-center justify-between gap-3 border-t px-5 py-2.5 text-[13px]">
                <div className="min-w-0">
                  <a href={r.url} className="font-medium hover:underline">#{r.issue} {r.name ?? r.title}</a>
                  <div className="text-[12px] text-muted">{[r.version, r.bundleID].filter(Boolean).join(", ") || "No app line"}</div>
                </div>
                <div className="flex items-center gap-2">
                  {r.verdict && <Tag tone={r.verdict === "works" ? "good" : r.verdict === "broken" ? "brand" : "caution"}>{r.verdict === "works" ? "Works" : r.verdict === "broken" ? "Broken" : "Problems"}</Tag>}
                  {r.approved
                    ? <Button disabled={busy} onClick={() => act("report", { action: "remove", issue: r.issue })}>Take off</Button>
                    : <Button disabled={busy || !r.bundleID || !r.verdict} onClick={() => act("report", { action: "approve", issue: r.issue })}>Approve</Button>}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="On the public list" note="Add apps from the Apps page.">
          {data.listed.length === 0 ? <Empty>None yet.</Empty> : (
            <ul className="grid gap-1.5 text-[13px]">
              {data.listed.map((app) => (
                <li key={app.bundle} className="flex items-center justify-between gap-3">
                  <span>{app.name} <span className="text-faint">{app.bundle}</span></span>
                  <Button disabled={busy} onClick={() => act("list", { action: "remove", bundle: app.bundle, name: "" })}>Remove</Button>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Donations" note="Ko-fi, the last year. The first goal: Apple's $99 a year to sign Parallex.">
          <div className="grid gap-3">
            <div className="flex items-baseline gap-2">
              <span className="tabular text-[26px] font-semibold tracking-tight">{dollars(raised)}</span>
              <span className="text-[12.5px] text-muted">of {dollars(GOAL_CENTS)}, from {number(data.donations.kofiCount)}</span>
            </div>
            <div className="h-2 overflow-hidden rounded-full bg-fill"><div className="h-full rounded-full bg-brand" style={{ width: `${Math.min(100, (raised / GOAL_CENTS) * 100)}%` }} /></div>
            {data.donations.otherCurrencies.length > 0 && <p className="text-[12px] text-faint">Also in {data.donations.otherCurrencies.join(", ")}, not added in.</p>}
            <p className="text-[12.5px] text-muted">
              GitHub Sponsors: {data.stats.sponsors != null ? `${number(stat("sponsors"))}, ${dollars(stat("sponsors_monthly_cents"))} a month` : "add a GitHub token to see"}
            </p>
            <ul className="grid gap-1 text-[12.5px] text-muted">
              {data.donations.recent.map((d, i) => (
                <li key={i} className="flex justify-between gap-3"><span>{d.kind}</span><span className="tabular">{d.currency === "USD" ? dollars(d.cents) : `${(d.cents / 100).toFixed(2)} ${d.currency}`}, {shortDay(d.at.slice(0, 10))}</span></li>
              ))}
            </ul>
          </div>
        </Card>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Log" note="What was done from here.">
          {data.log.length === 0 ? <Empty>Nothing yet.</Empty> : (
            <ul className="grid gap-1.5 text-[12.5px]">
              {data.log.map((entry, i) => (
                <li key={i} className="grid grid-cols-[88px_minmax(0,1fr)] gap-3">
                  <span className="tabular text-faint">{shortDay(entry.at.slice(0, 10))}</span>
                  <span><span className="font-medium">{entry.action}</span> <span className="text-muted">{entry.detail}</span></span>
                </li>
              ))}
            </ul>
          )}
        </Card>
        <Card title="Export" note="Added up per day, as CSV. Never install numbers.">
          <div className="flex flex-wrap gap-2">
            {[["releases", "Macs per version"], ["events", "Events"], ["crashes", "Crashes"], ["checks", "Update checks"]].map(([table, label]) => (
              <a key={table} href={`/admin/export/${table}.csv`} className="inline-flex h-8 items-center gap-1.5 rounded-full border bg-surface px-3.5 text-[12.5px] font-medium hover:border-faint [&_svg]:size-3.5">
                <Download />{label}
              </a>
            ))}
          </div>
        </Card>
      </div>
    </>
  )
}
