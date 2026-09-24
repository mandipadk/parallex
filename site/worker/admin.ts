import type { Summary } from "./summary"

const escape = (text: string) =>
  text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c)
const number = (n: number) => n.toLocaleString("en-US")
/** "1 Mac", "3 Macs". */
const plural = (n: number, one: string, many = `${one}s`) => `${number(n)} ${n === 1 ? one : many}`
const dollars = (cents: number) => `$${(cents / 100).toLocaleString("en-US", { maximumFractionDigits: cents % 100 ? 2 : 0 })}`

const REPO = "https://github.com/mandipadk/parallex"
const GOAL_CENTS = 9900

const styles = `
:root {
  --ground: #f5f5f3; --surface: #ffffff; --ink: #18191b; --muted: #62656b; --faint: #8b8e94;
  --rule: #e4e4e0; --fill: #efefec; --accent: #e0461a; --accent-soft: #fbe8e1; --good: #2f7d4f;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground: #121314; --surface: #1b1c1e; --ink: #ececea; --muted: #a2a5ab; --faint: #75787e;
    --rule: #2b2d30; --fill: #25272a; --accent: #ff6a3d; --accent-soft: #3a1f17; --good: #6cc792;
    color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --ground: #121314; --surface: #1b1c1e; --ink: #ececea; --muted: #a2a5ab; --faint: #75787e;
  --rule: #2b2d30; --fill: #25272a; --accent: #ff6a3d; --accent-soft: #3a1f17; --good: #6cc792;
  color-scheme: dark;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--ground); color: var(--ink); font: 15px/1.5 "Geist", -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
main { max-width: 1080px; margin: 0 auto; padding: 32px 16px 64px; display: grid; gap: 16px; }
header { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding-bottom: 8px; flex-wrap: wrap; }
.brand { display: flex; align-items: center; gap: 12px; }
.brand h1 { font-size: 22px; font-weight: 650; margin: 0; letter-spacing: -0.01em; }
.brand p { margin: 0; color: var(--muted); font-size: 13px; }
.actions { display: flex; gap: 8px; }
button, .button { font: inherit; font-size: 13px; font-weight: 500; border: 1px solid var(--rule); background: var(--surface); color: var(--ink); border-radius: 999px; padding: 6px 14px; cursor: pointer; text-decoration: none; }
button:hover, .button:hover { border-color: var(--faint); }
button:focus-visible, a:focus-visible, input:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.card { background: var(--surface); border: 1px solid var(--rule); border-radius: 16px; padding: 20px; display: grid; gap: 14px; align-content: start; min-width: 0; }
.card h2 { font-size: 14px; font-weight: 600; margin: 0; }
.card .sub { color: var(--muted); font-size: 13px; margin: -10px 0 0; }
.kpis { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px; }
.kpi { gap: 4px; }
.kpi .label { color: var(--muted); font-size: 13px; }
.kpi .value { font-size: 34px; font-weight: 650; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; line-height: 1.1; }
.kpi .note { color: var(--faint); font-size: 12px; }
.grid3 { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px; }
.grid2 { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 16px; }
.bars { display: grid; gap: 10px; }
.bar { display: grid; gap: 4px; }
.bar .row { display: flex; justify-content: space-between; gap: 12px; font-size: 13px; }
.bar .row span:last-child { color: var(--muted); font-variant-numeric: tabular-nums; }
.bar .track { height: 6px; border-radius: 999px; background: var(--fill); overflow: hidden; }
.bar .fill { height: 100%; border-radius: 999px; background: var(--accent); }
.chart svg { width: 100%; height: 180px; display: block; }
.chart .axis { display: flex; justify-content: space-between; color: var(--faint); font-size: 12px; }
.legend { display: flex; gap: 16px; color: var(--muted); font-size: 12px; }
.legend i { display: inline-block; width: 8px; height: 8px; border-radius: 2px; margin-right: 6px; vertical-align: 1px; }
.empty { color: var(--faint); font-size: 13px; }
.goal .track { height: 10px; }
.money { display: flex; align-items: baseline; gap: 8px; }
.money b { font-size: 26px; font-weight: 650; font-variant-numeric: tabular-nums; }
.money span { color: var(--muted); font-size: 13px; }
.list { display: grid; gap: 8px; font-size: 13px; }
.list div { display: flex; justify-content: space-between; gap: 12px; }
.list div span:last-child { color: var(--muted); font-variant-numeric: tabular-nums; }
.stats { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
.release-head { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; flex-wrap: wrap; }
.release-head b { font-size: 22px; font-weight: 650; font-variant-numeric: tabular-nums; margin-right: 6px; }
.muted { color: var(--muted); font-size: 13px; }
.chip { display: inline-block; font-size: 12px; font-weight: 500; padding: 2px 9px; border-radius: 999px; background: color-mix(in srgb, var(--good) 16%, transparent); color: var(--good); vertical-align: 3px; }
.chip.warn { background: var(--accent-soft); color: var(--accent); }
.controls { display: flex; gap: 8px; flex-wrap: wrap; }
.controls form, .list form { margin: 0; }
button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
button.current { background: var(--ink); border-color: var(--ink); color: var(--surface); }
.list button { padding: 2px 10px; font-size: 12px; }
.stats a { color: inherit; text-decoration: none; display: grid; gap: 2px; padding: 12px; border-radius: 12px; background: var(--fill); }
.stats a:hover { outline: 1px solid var(--rule); }
.stats b { font-size: 22px; font-weight: 650; font-variant-numeric: tabular-nums; }
.stats span { color: var(--muted); font-size: 12px; }
footer { color: var(--faint); font-size: 12px; text-align: center; padding-top: 8px; }
footer a { color: var(--muted); }
@media (max-width: 860px) {
  .kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); }
  .grid3, .grid2 { grid-template-columns: 1fr; }
}
@media (max-width: 420px) { .kpi .value { font-size: 28px; } .stats { grid-template-columns: 1fr 1fr; } }
`

const mark = `<svg width="28" height="28" viewBox="0 0 64 64" aria-hidden="true"><rect x="8" y="8" width="36" height="36" rx="10" fill="none" stroke="var(--faint)" stroke-width="3"/><rect x="20" y="20" width="36" height="36" rx="10" fill="var(--accent)"/></svg>`

function page(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${title}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&display=swap">
<style>${styles}</style></head><body>${body}</body></html>`
}

export function signInPage(failed: boolean, configured: boolean): string {
  return page("Mission Control", `<main style="max-width:380px;padding-top:18vh">
  <div class="card" style="gap:18px">
    <div class="brand">${mark}<div><h1>Mission Control</h1><p>Parallex, by the numbers</p></div></div>
    ${configured
      ? `<form method="post" action="/admin/sign-in" style="display:grid;gap:12px">
      <label for="token" style="font-size:13px;color:var(--muted)">Admin key</label>
      <input id="token" name="token" type="password" autocomplete="current-password" required autofocus
        style="font:inherit;padding:10px 12px;border-radius:10px;border:1px solid var(--rule);background:var(--ground);color:var(--ink)">
      ${failed ? `<p style="margin:0;color:var(--accent);font-size:13px">That key isn't right.</p>` : ""}
      <button type="submit" style="background:var(--accent);border-color:var(--accent);color:#fff;padding:10px">Sign in</button>
    </form>`
      : `<p class="empty">Set an admin key first: <code>wrangler secret put ADMIN_TOKEN</code>.</p>`}
  </div></main>`)
}

/** Bars sized by share; each shows its share, or its count with `counts`. */
function bars(items: { name: string; count: number }[], label: (name: string) => string = (n) => n, counts = false): string {
  if (!items.length) return `<p class="empty">Nothing yet.</p>`
  const total = items.reduce((s, i) => s + Number(i.count), 0) || 1
  return `<div class="bars">${items
    .map((i) => {
      const share = (Number(i.count) / total) * 100
      const shown = counts ? number(Number(i.count)) : Number(i.count) === 0 ? "0%" : share < 1 ? "<1%" : `${Math.round(share)}%`
      return `<div class="bar"><div class="row"><span>${escape(label(i.name))}</span><span>${shown}</span></div>
      <div class="track"><div class="fill" style="width:${share.toFixed(1)}%"></div></div></div>`
    })
    .join("")}</div>`
}

function chart(series: Summary["series"]): string {
  const width = 600
  const height = 180
  const max = Math.max(1, ...series.map((d) => d.active))
  const step = width / series.length
  const barWidth = Math.max(2, step - 4)
  const columns = series
    .map((d, i) => {
      const h = (d.active / max) * (height - 8)
      const f = (d.fresh / max) * (height - 8)
      const x = i * step + (step - barWidth) / 2
      return `<g><title>${d.day}: ${number(d.active)} active, ${number(d.fresh)} new</title>
        <rect x="${x.toFixed(1)}" y="${(height - h).toFixed(1)}" width="${barWidth.toFixed(1)}" height="${h.toFixed(1)}" rx="3" fill="var(--accent)" opacity="0.9"/>
        <rect x="${(x + barWidth * 0.3).toFixed(1)}" y="${(height - f).toFixed(1)}" width="${(barWidth * 0.4).toFixed(1)}" height="${f.toFixed(1)}" rx="1.5" fill="var(--ink)"/></g>`
    })
    .join("")
  const short = (day: string) => new Date(`${day}T00:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" })
  return `<div class="chart"><svg viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img" aria-label="Daily active installs, last 30 days">
    <line x1="0" y1="${height - 0.5}" x2="${width}" y2="${height - 0.5}" stroke="var(--rule)"/>${columns}</svg>
    <div class="axis"><span>${short(series[0].day)}</span><span>Today</span></div></div>`
}

/** A one-button form that posts a release action. */
function action(label: string, fields: Record<string, string>, options: { primary?: boolean; confirm?: string; current?: boolean } = {}): string {
  const inputs = Object.entries(fields).map(([k, v]) => `<input type="hidden" name="${k}" value="${escape(v)}">`).join("")
  // A JavaScript string (JSON), then escaped for the attribute it sits in.
  const confirm = options.confirm ? ` onsubmit="return confirm(${escape(JSON.stringify(options.confirm))})"` : ""
  const style = options.current ? ` class="current" aria-pressed="true"` : options.primary ? ` class="primary"` : ""
  return `<form method="post" action="/admin/release"${confirm}>${inputs}<button type="submit"${style}>${escape(label)}</button></form>`
}

function releasesCard(s: Summary): string {
  const [newest, ...earlier] = s.published
  if (!newest) return `<section class="card" id="releases"><h2>Releases</h2><p class="empty">No releases found.</p></section>`
  const r = s.rollout
  const pulled = (v: string) => r.pulled.includes(v)
  const steered = r.version === newest
  const share = steered ? r.percent : 100
  const paused = steered && r.paused
  const status = pulled(newest) ? "Pulled: no one gets it" : paused ? `Paused at ${share}%` : share >= 100 ? "Out to everyone" : `Out to ${share}% of Macs`
  const today = s.todayVersions.reduce((sum, v) => sum + Number(v.count), 0)
  const onNewest = Number(s.todayVersions.find((v) => v.name === newest)?.count ?? 0)
  const shares = [10, 50, 100]
    .map((p) => action(p === 100 ? "Everyone" : `${p}%`, { action: "share", version: newest, percent: String(p) }, { current: !paused && !pulled(newest) && share === p }))
    .join("")
  return `<section class="card" id="releases">
    <h2>Releases</h2>
    <p class="sub">Macs on 0.20 or later follow this (the share needs 0.21). A pulled release is skipped: they're offered the one before it.</p>
    <div class="release-head">
      <div><b>${escape(newest)}</b> <span class="chip${pulled(newest) || paused ? " warn" : ""}">${escape(status)}</span></div>
      <span class="muted">${today ? `On it today: ${Math.round((onNewest / today) * 100)}% of ${number(today)} Macs` : "No checks yet today"}</span>
    </div>
    <div class="controls">
      ${pulled(newest) ? action("Put back", { action: "restore", version: newest }, { primary: true }) : `${shares}
      ${paused ? action("Resume", { action: "resume", version: newest }, { primary: true }) : action("Pause", { action: "pause", version: newest })}
      ${action("Pull", { action: "pull", version: newest }, { confirm: `Pull ${newest}? Macs on 0.20 or later won't be offered it and get the release before it instead. Macs already on it keep it, and older Parallex versions or Macs that can't reach this server ask GitHub, which a pull doesn't change: to stop it everywhere, also make it a draft on GitHub.` })}`}
    </div>
    <div class="release-head"><span class="muted">New releases start at</span><div class="controls">
      ${action("10%", { action: "start", version: newest, percent: "10" }, { current: r.startPercent === 10 })}
      ${action("Everyone", { action: "start", version: newest, percent: "100" }, { current: r.startPercent >= 100 })}
    </div></div>
    ${earlier.length ? `<div class="list">${earlier
      .map((v) => `<div><span>${escape(v)}${pulled(v) ? " · pulled" : ""}</span><span>${pulled(v)
        ? action("Put back", { action: "restore", version: v })
        : action("Pull", { action: "pull", version: v }, { confirm: `Pull ${v}? No one will be offered it.` })}</span></div>`)
      .join("")}</div>` : ""}
  </section>`
}

const FEATURE_NAMES: Record<string, string> = {
  workspaces: "Workspaces", throwaway: "Throwaways", hideFromDock: "Hidden from the Dock", menuBarIcon: "Menu bar icons",
  shortcut: "Shortcuts", quitWhenUnused: "Quit when unused", openAtLaunch: "Open at launch", shareMCPServers: "Shared MCP servers",
  signInLinks: "Sign-in link routing", webLinks: "Web link routing", "website:other": "Other websites",
}
const featureName = (key: string) => FEATURE_NAMES[key] ?? (key.startsWith("website:") ? key.slice(8) : key)

function usageSection(s: Summary): string {
  const u = s.usage
  if (!u.macs30) {
    return `<section class="card"><h2>Opt-in usage</h2><p class="sub">Macs that turned on Share anonymous usage</p>
      <p class="empty">No reports yet. They come from Macs on 0.21 or later that turn it on in Settings › About.</p></section>`
  }
  const pct = (part: number, whole: number) => (whole ? `${Math.round((part / whole) * 100)}%` : "–")
  const apps = u.apps.map((a) => `<div><span>${escape(a.name)} <span class="muted" style="font-size:11px">${escape(a.bundle)}</span></span><span>${plural(Number(a.macs), "Mac")} · ${plural(Number(a.instances), "instance")} · ${
    Number(a.failing) ? `<span style="color:var(--accent)">${pct(Number(a.failing), Number(a.macs))} quit at launch</span>` : "working"}${
    Number(a.verified) ? ` · ${pct(Number(a.verified), Number(a.macs))} verified` : ""}</span></div>`).join("")
  const warnings = u.warnings.length
    ? u.warnings.map((w) => `<div><span><b style="color:var(--accent)">${escape(w.name)} ${escape(w.version)}</b></span><span>copies quit at launch on ${number(Number(w.failing))} of ${plural(Number(w.macs), "Mac")}</span></div>`).join("")
    : `<p class="empty">Nothing is going wrong that the reports show.</p>`
  return `<section class="grid2">
    <div class="card"><h2>Apps people copy</h2><p class="sub">${plural(u.macs30, "report")} in the last 30 days, ${number(u.macs7)} this week</p>
      <div class="list">${apps || `<p class="empty">No apps yet.</p>`}</div></div>
    <div class="card"><h2>Early warnings</h2><p class="sub">An app version whose copies quit at launch on 2 or more Macs, last 7 days</p>
      <div class="list">${warnings}</div>
      <h2 style="margin-top:8px">Features</h2><p class="sub">Reporting Macs using each, last 30 days</p>
      ${bars(u.features.map((f) => ({ name: featureName(f.name), count: Number(f.macs) })), (n) => n, true)}</div>
  </section>`
}

export function dashboardPage(s: Summary): string {
  const sponsorsMonthly = s.stats.sponsors_monthly_cents ?? 0
  const yearly = s.donations.kofiCents + sponsorsMonthly * 12
  const goalShare = Math.min(100, (yearly / GOAL_CENTS) * 100)
  const hasChecks = s.series.some((d) => d.active > 0) || s.active.month > 0
  const updated = new Date(s.generated).toLocaleString("en-US", { dateStyle: "medium", timeStyle: "short", timeZone: "America/Chicago" })
  const downloads = (s.stats.downloads_dmg ?? 0) + (s.stats.downloads_zip ?? 0)

  return page("Mission Control · Parallex", `<main>
  <header>
    <div class="brand">${mark}<div><h1>Mission Control</h1><p>Counts, never people · ${escape(updated)}</p></div></div>
    <div class="actions">
      <form method="post" action="/admin/collect"><button type="submit">Refresh GitHub numbers</button></form>
      <form method="post" action="/admin/sign-out"><button type="submit" title="Ends every session, on every device">Sign out</button></form>
    </div>
  </header>

  <section class="kpis">
    <div class="card kpi"><span class="label">Active today</span><span class="value">${number(s.active.day)}</span><span class="note">Macs that checked for updates</span></div>
    <div class="card kpi"><span class="label">This week</span><span class="value">${number(s.active.week)}</span><span class="note">Since Monday</span></div>
    <div class="card kpi"><span class="label">This month</span><span class="value">${number(s.active.month)}</span><span class="note">Since the 1st</span></div>
    <div class="card kpi"><span class="label">New this week</span><span class="value">${number(s.newThisWeek)}</span><span class="note">${s.installsThisMonth === 1 ? "1 Terminal install" : `${number(s.installsThisMonth)} Terminal installs`} this month</span></div>
  </section>

  <section class="card">
    <h2>Daily active installs</h2>
    <p class="sub">Last 30 days</p>
    ${hasChecks ? chart(s.series) : `<p class="empty">No update checks yet. They start arriving as people update to 0.20.</p>`}
    <div class="legend"><span><i style="background:var(--accent)"></i>Active</span><span><i style="background:var(--ink)"></i>New</span></div>
  </section>

  ${releasesCard(s)}

  ${usageSection(s)}

  <section class="grid3">
    <div class="card"><h2>Version</h2><p class="sub">Share of checks, last 7 days</p>${bars(s.versions, (n) => (n === "other" ? "Other" : n))}</div>
    <div class="card"><h2>macOS</h2><p class="sub">Last 7 days</p>${bars(s.os, (n) => (n === "other" ? "Other" : `macOS ${n}`))}</div>
    <div class="card"><h2>Chip</h2><p class="sub">Last 7 days</p>${bars(s.arch, (n) => (n === "arm64" ? "Apple silicon" : n === "x86_64" ? "Intel" : "Other"))}</div>
  </section>

  <section class="grid2">
    <div class="card goal">
      <h2>Toward notarization</h2>
      <p class="sub">$99 a year for Apple's Developer ID</p>
      <div class="money"><b>${dollars(yearly)}</b><span>a year of $99</span></div>
      <div class="bar"><div class="track"><div class="fill" style="width:${goalShare.toFixed(1)}%"></div></div></div>
      <div class="list">
        <div><span>GitHub Sponsors</span><span>${s.stats.sponsors != null ? `${number(s.stats.sponsors)} · ${dollars(sponsorsMonthly)}/mo` : "Add a GitHub token to see"}</span></div>
        <div><span>Ko-fi, last 12 months</span><span>${dollars(s.donations.kofiCents)} · ${number(s.donations.kofiCount)}${s.donations.otherCurrencies.length ? ` · plus ${escape(s.donations.otherCurrencies.join(", "))}` : ""}</span></div>
        ${s.donations.recent.map((d) => `<div><span>${escape(d.kind)} · ${escape(d.at.slice(0, 10))}</span><span>${escape(dollars(Number(d.cents)))} ${escape(d.currency)}</span></div>`).join("")}
      </div>
    </div>
    <div class="card">
      <h2>Downloads</h2>
      <p class="sub">${number(downloads)} in all · ${number(s.stats.downloads_dmg ?? 0)} disk images, ${number(s.stats.downloads_zip ?? 0)} updates and Terminal installs</p>
      ${s.releases.length ? bars(s.releases.map((r) => ({ name: r.tag, count: r.downloads })), (n) => n, true) : `<p class="empty">Refresh GitHub numbers to see them.</p>`}
    </div>
  </section>

  <section class="card">
    <h2>Community</h2>
    <div class="stats">
      <a href="${REPO}/stargazers"><b>${number(s.stats.stars ?? 0)}</b><span>Stars</span></a>
      <a href="${REPO}/issues?q=label%3Acompatibility"><b>${number(s.stats.compat_reports ?? 0)}</b><span>Compatibility reports</span></a>
      <a href="${REPO}/issues"><b>${number(s.stats.open_issues ?? 0)}</b><span>Open issues and PRs</span></a>
    </div>
  </section>

  <footer>Only counts are stored: version, macOS, chip and day. <a href="/privacy">What leaves a Mac</a></footer>
</main>`)
}
