import { ArrowRight } from "lucide-react"
import type { Overview } from "../../../worker/mission-types"
import { useApi } from "../api"
import { LineChart } from "../charts"
import { number, percent, plural } from "../format"
import type { PageProps } from "../main"
import { Card, Empty, Loading, PageHead, Problem, Stat, VerdictTag } from "../ui"

export function OverviewPage({ days, go }: PageProps) {
  const { data, error } = useApi<Overview>("overview", days)
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />
  const day = data.series.map((s) => s.day)
  return (
    <>
      <PageHead title="Overview" note="Every Mac that checks for updates, and what the Macs that share usage say about how Parallex is doing." />

      {data.alerts.length > 0 && (
        <div className="grid gap-2">
          {data.alerts.map((alert, i) => (
            <button
              key={i}
              onClick={() => go(alert.tab)}
              className={`group flex items-center justify-between gap-4 rounded-2xl border px-5 py-3.5 text-left transition-colors ${
                alert.level === "failing" ? "border-brand/35 bg-brand-soft" : "border-caution/30 bg-caution-soft"
              }`}
            >
              <div className="min-w-0">
                <div className={`text-[13.5px] font-semibold ${alert.level === "failing" ? "text-brand" : "text-caution"}`}>{alert.title}</div>
                <div className="truncate text-[12.5px] text-muted">{alert.detail}</div>
              </div>
              <ArrowRight className="size-4 shrink-0 text-muted transition-transform group-hover:translate-x-0.5" />
            </button>
          ))}
        </div>
      )}

      <div className="grid grid-cols-2 gap-4 lg:grid-cols-3 xl:grid-cols-5">
        <Stat
          label="Macs, last 30 days"
          value={number(data.macs.month + data.macs.olderThisMonth)}
          tone="brand"
          note={data.macs.olderThisMonth
            ? `${number(data.macs.month)} counted once each, and about ${number(data.macs.olderThisMonth)} on versions before 1.7 this month`
            : `each counted once; ${number(data.macs.quarter)} in 90 days, ${number(data.macs.ever)} since 1.7`}
        />
        <Stat label="Macs today" value={number(data.active.day)} note={`${number(data.macs.week)} in the last 7 days`} />
        <Stat label="New this week" value={number(data.newThisWeek)} note={`${number(data.sharing.newThisWeek)} of them sharing usage`} />
        <Stat label="Sharing usage" value={number(data.sharing.week)} note={`in the last 7 days; ${number(data.sharing.day)} today`} />
        <Stat
          label="Crash-free, latest"
          value={data.latest?.health.crashFree == null ? "–" : percent(data.latest.health.crashFree, 1)}
          tone={data.latest?.health.crashFree != null && data.latest.health.crashFree >= 0.995 ? "good" : undefined}
          note={data.latest ? `${data.latest.version}, ${plural(data.latest.macs, "Mac")}` : "No release yet"}
        />
      </div>

      <div className="grid items-start gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <Card title="Macs, day by day" note="Update checks count every Mac; usage reports count those that share.">
          <LineChart
            days={day}
            series={[
              { key: "active", label: "Checking for updates", color: "var(--brand)", values: data.series.map((s) => s.active) },
              { key: "sharing", label: "Sharing usage", color: "var(--series-2)", values: data.series.map((s) => s.sharing) },
              { key: "fresh", label: "New", color: "var(--series-3)", values: data.series.map((s) => s.fresh) },
            ]}
          />
        </Card>
        <div className="grid content-start gap-4">
          <Card
            title="Latest release"
            action={data.latest && <VerdictTag verdict={data.latest.health.verdict} />}
          >
            {data.latest ? (
              <div className="grid gap-3">
                <div className="flex items-baseline gap-2">
                  <span className="tabular text-[26px] font-semibold tracking-tight">{data.latest.version}</span>
                  <span className="text-[12.5px] text-muted">on {percent(data.latest.adoption)} of Macs today</span>
                </div>
                {data.latest.health.reasons.length ? (
                  <ul className="grid gap-1 text-[12.5px] text-muted">{data.latest.health.reasons.map((r) => <li key={r}>{r}</li>)}</ul>
                ) : (
                  <p className="text-[12.5px] text-muted">Nothing out of the ordinary.</p>
                )}
                <button onClick={() => go("releases")} className="justify-self-start text-[12.5px] font-medium text-brand hover:underline">Scorecard and rollout</button>
              </div>
            ) : <Empty>No published release found.</Empty>}
          </Card>
          <Card title="What people have" note="Latest report of each sharing Mac, last 7 days.">
            <dl className="grid grid-cols-2 gap-x-4 gap-y-3">
              <Figure label="Instances" value={data.totals.instances} />
              <Figure label="Own-identity copies" value={data.totals.copies} />
              <Figure label="Website instances" value={data.totals.web} />
              <Figure label={`Made in ${days} days`} value={data.totals.created} />
              <Figure label={`Snapshots in ${days} days`} value={data.totals.snapshots} />
            </dl>
          </Card>
        </div>
      </div>

      <Card title="Crashes, day by day" note="Parallex's own crashes, as macOS reports them to Macs that share usage.">
        <LineChart days={day} height={140} series={[{ key: "crashes", label: "Crashes", color: "var(--brand)", values: data.series.map((s) => s.crashes) }]} />
      </Card>
    </>
  )
}

function Figure({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <dt className="text-[12px] text-muted">{label}</dt>
      <dd className="tabular text-[20px] font-semibold tracking-tight">{number(value)}</dd>
    </div>
  )
}
