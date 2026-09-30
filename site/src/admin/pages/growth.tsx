import type { Growth } from "../../../worker/mission-types"
import { useApi } from "../api"
import { Meter } from "../charts"
import { number, percent, shortDay } from "../format"
import type { PageProps } from "../main"
import { Bars, Card, Empty, Loading, PageHead, Problem } from "../ui"

const FEATURES: Record<string, string> = {
  workspaces: "Workspaces", throwaway: "Throwaways", hideFromDock: "Hidden from the Dock", menuBarIcon: "Menu bar icons",
  shortcut: "Keyboard shortcuts", quitWhenUnused: "Quit when unused", openAtLaunch: "Open at login", shareMCPServers: "Shared MCP servers",
  signInLinks: "Sign-in link routing", webLinks: "Web link routing", snapshots: "Snapshots", dailySnapshots: "Daily snapshots",
  pinnedVersion: "Pinned app versions", persona: "Personas", proxy: "Proxies", shareSettings: "Shared editor settings",
  guard: "Guard", separateKeychain: "Separate keychains", privateItems: "Private items",
}

export function GrowthPage({ days }: PageProps) {
  const { data, error } = useApi<Growth>("growth", days)
  if (error && !data) return <Problem>{error}</Problem>
  if (!data) return <Loading />
  const top = Math.max(1, ...data.funnel.map((f) => f.macs))
  const onboardingTop = Math.max(1, ...data.onboarding.map((s) => s.count))
  return (
    <>
      <PageHead title="Growth" note="Where new Macs come from, how far they get, and whether they stay." />

      <div className="grid gap-4 xl:grid-cols-2">
        <Card title="From install to habit" note={`New Macs in the last ${days} days. Steps after the first two count Macs that share usage.`}>
          <ol className="grid gap-3">
            {data.funnel.map((step, i) => {
              const before = i > 0 ? data.funnel[i - 1].macs : 0
              return (
                <li key={step.step} className="grid gap-1">
                  <div className="flex items-baseline justify-between gap-3 text-[13px]">
                    <span>{step.label}</span>
                    <span className="tabular text-muted">
                      {number(step.macs)}
                      {i > 1 && before > 0 && <span className="ml-1.5 text-faint">{percent(step.macs / before)}</span>}
                    </span>
                  </div>
                  <Meter value={step.macs / top} />
                </li>
              )
            })}
          </ol>
        </Card>
        <Card title="First-run setup" note="Macs reaching each step, of those that shared usage at the end.">
          <ol className="grid gap-3">
            {data.onboarding.map((step) => (
              <li key={step.name} className="grid gap-1">
                <div className="flex items-baseline justify-between gap-3 text-[13px]"><span>{step.name}</span><span className="tabular text-muted">{number(step.count)}</span></div>
                <Meter value={step.count / onboardingTop} />
              </li>
            ))}
          </ol>
        </Card>
      </div>

      <Card title="Coming back" note="Of each week's new Macs, the share still reporting each week after. Weeks before reports began aren't shown.">
        {data.cohorts.length === 0 ? <Empty>Cohorts fill in as weeks pass.</Empty> : (
          <div className="overflow-x-auto">
            <table className="tabular w-full min-w-[640px] border-separate border-spacing-1 text-[12px]">
              <thead>
                <tr className="text-muted">
                  <th className="px-2 text-left font-medium">Week of</th>
                  <th className="px-2 text-right font-medium">Macs</th>
                  {Array.from({ length: Math.max(...data.cohorts.map((c) => c.weeks.length)) }, (_, k) => (
                    <th key={k} className="px-2 text-center font-medium">{k === 0 ? "First" : `+${k}`}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {data.cohorts.map((cohort) => (
                  <tr key={cohort.cohort}>
                    <td className="px-2 whitespace-nowrap">{cohort.start ? shortDay(cohort.start) : cohort.cohort}</td>
                    <td className="px-2 text-right text-muted">{number(cohort.size)}</td>
                    {cohort.weeks.map((share, k) => (
                      <td key={k} className="h-8 min-w-12 rounded-md text-center"
                        style={{ background: `color-mix(in oklab, var(--brand) ${Math.round(share * 70)}%, var(--fill))`, color: share > 0.55 ? "white" : undefined }}>
                        {percent(share)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Card>

      <div className="grid gap-4 lg:grid-cols-2">
        <Card title="Features in use" note="Share of Macs sharing usage in the last 7 days.">
          {data.features.length === 0 ? <Empty>Nothing yet.</Empty> : (
            <Bars items={data.features.map((f) => ({ name: FEATURES[f.feature] ?? f.feature, count: f.share }))} total={1} format={(x) => percent(x)} limit={20} />
          )}
        </Card>
        <div className="grid content-start gap-4">
          <Card title="Where instances are made" note="The app, Terminal or Shortcuts.">
            <Bars items={data.sources.map((s) => ({ ...s, name: s.name === "cli" ? "Terminal" : s.name === "app" ? "The app" : s.name }))} />
          </Card>
          <Card title="Terminal commands" note="How often each ran.">
            <Bars items={data.commands} limit={12} empty="No commands yet." />
          </Card>
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <Card title="macOS"><Bars items={data.platforms.os} /></Card>
        <Card title="Chip"><Bars items={data.platforms.arch.map((a) => ({ ...a, name: a.name === "arm64" ? "Apple silicon" : a.name === "x86_64" ? "Intel" : a.name }))} /></Card>
        <Card title="Parallex version"><Bars items={data.platforms.version} /></Card>
      </div>
    </>
  )
}
