/**
 * The search pages: one per app people want to run twice (/apps/<slug>),
 * an index (/apps), a sitemap and robots.txt, written into dist/ after the
 * site is built (see build.ts). Static HTML: readable without JavaScript.
 */

export type LabResult = { app: string; version?: string; result: string; leaks?: number; blocked?: number }
export type LabRun = { date: string; macos: string; apps: LabResult[] }
/** Each app's nights in the lab, newest first. */
export type LabHistory = Record<string, { day: string; version: string; result: string }[]>

const longDay = (day: string) =>
  new Date(`${day}T00:00:00Z`).toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "UTC" })

/** What an app's nights add up to, in a sentence (or nothing to say yet). */
export function historyLine(nights: { day: string; version: string; result: string }[] | undefined): string {
  const tried = (nights ?? []).filter((n) => ["ran", "quit", "crashed", "leaked"].includes(n.result))
  if (tried.length < 2) return ""
  let streak = 0
  while (streak < tried.length && tried[streak].result === "ran") streak++
  if (streak === tried.length) return `Its copies have run clean on all ${tried.length} nights since ${longDay(tried[tried.length - 1].day)}.`
  if (streak === 0) return ""
  const trouble = tried[streak]
  const what = trouble.result === "quit" ? "quit at launch" : trouble.result
  return `Its copies last had trouble on ${longDay(trouble.day)} (${trouble.version ? `${trouble.version}, ` : ""}${what}), and have run clean on the ${streak} ${streak === 1 ? "night" : "nights"} since.`
}

export type Guide = {
  slug: string
  /** The app's name, as people search for it. */
  app: string
  /** Its name in the nightly lab, when it's there. */
  labName?: string
  /** What people search for: "Two Slack accounts on one Mac". */
  title: string
  /** One sentence for search results. */
  description: string
  /** Why someone wants two: one or two sentences. */
  why: string
  /** What Parallex does for this app in particular (from its code). */
  specifics: string[]
  /** What a copy can't do, or does differently. */
  limits: string[]
  /** Questions people ask, answered plainly (also given to search engines). */
  questions: { q: string; a: string }[]
  /** Other pages to point to. */
  related: string[]
  /** An instance of it has its own Dock icon (copies and website
   *  instances do; a browser's instance is a launcher, outlined instead). */
  ownDock?: boolean
  /** The app's name in Applications, for the "make this copy" link
   *  (parallex://new?app=…); none when the page is about a website. */
  appRef?: string | null
}

const SITE = "https://parallex.mandip.dev"
const INSTALL = "curl -fsSL https://parallex.mandip.dev/install | sh"
const RELEASES = "https://github.com/mandipadk/parallex/releases/latest"

const escape = (text: string) =>
  text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c)

/** Plain text with `code` and **bold** spans. */
const inline = (text: string) =>
  escape(text).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")

const styles = `
:root { --background: oklch(0.1149 0 0); --card: oklch(0.155 0 0); --foreground: oklch(0.985 0 0); --muted: oklch(0.708 0 0); --subtle: oklch(0.52 0 0); --rule: oklch(1 0 0 / 0.08); --accent: #ff6a3d; --good: oklch(0.76 0.13 155); color-scheme: dark; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--background); color: var(--foreground); font: 16px/1.65 "Geist", -apple-system, system-ui, sans-serif; -webkit-font-smoothing: antialiased; }
main { max-width: 720px; margin: 0 auto; padding: 72px 16px 96px; display: grid; gap: 40px; }
a { color: var(--foreground); text-decoration-color: oklch(1 0 0 / 0.3); text-underline-offset: 3px; }
a:hover { text-decoration-color: var(--foreground); }
a:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 3px; }
.back { color: var(--muted); font-size: 14px; text-decoration: none; }
h1 { font-size: clamp(34px, 6vw, 48px); line-height: 1.08; letter-spacing: -0.03em; margin: 0; font-weight: 650; text-wrap: balance; }
h2 { font-size: 21px; letter-spacing: -0.01em; margin: 0 0 6px; font-weight: 600; }
h3 { font-size: 16px; margin: 0; font-weight: 600; }
p, li { color: var(--muted); }
p { margin: 0; }
.lede { font-size: 18px; }
section { display: grid; gap: 12px; }
ul, ol { margin: 0; padding-left: 20px; display: grid; gap: 8px; }
b { color: var(--foreground); font-weight: 600; }
code { font-family: "Geist Mono", ui-monospace, monospace; font-size: 0.86em; background: var(--card); padding: 2px 6px; border-radius: 6px; color: var(--foreground); }
.install { display: grid; gap: 10px; background: var(--card); border: 1px solid var(--rule); border-radius: 18px; padding: 20px; }
.install pre { margin: 0; font-family: "Geist Mono", ui-monospace, monospace; font-size: 14px; color: var(--foreground); overflow-x: auto; }
.install p { font-size: 14px; }
.cta { display: inline-flex; align-items: center; height: 40px; padding: 0 18px; border-radius: 999px; background: var(--accent); color: #fff; font-weight: 600; text-decoration: none; justify-self: start; }
.lab { border-left: 2px solid var(--good); padding-left: 16px; }
.lab.not { border-left-color: var(--accent); }
.lab-slot { display: contents; }
.qa { display: grid; gap: 18px; }
.qa div { display: grid; gap: 4px; }
figure { margin: 0; }
figure img { width: 100%; height: auto; display: block; border-radius: 14px; border: 1px solid var(--rule); }
figcaption { color: var(--subtle); font-size: 13px; margin-top: 10px; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 1px; background: var(--rule); border: 1px solid var(--rule); border-radius: 16px; overflow: hidden; }
.grid a { background: var(--background); padding: 16px 18px; text-decoration: none; display: grid; gap: 2px; }
.grid a:hover { background: var(--card); }
.grid span { color: var(--muted); font-size: 14px; }
footer { color: var(--subtle); font-size: 13px; border-top: 1px solid var(--rule); padding-top: 20px; display: flex; gap: 16px; flex-wrap: wrap; }
footer a { color: var(--muted); }
`

function shell(o: { title: string; description: string; path: string; body: string; jsonLD?: object[] }): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(o.title)}</title>
<meta name="description" content="${escape(o.description)}">
<link rel="canonical" href="${SITE}${o.path}">
<meta property="og:type" content="article">
<meta property="og:site_name" content="Parallex">
<meta property="og:title" content="${escape(o.title)}">
<meta property="og:description" content="${escape(o.description)}">
<meta property="og:url" content="${SITE}${o.path}">
<meta property="og:image" content="${SITE}/og.png">
<meta name="twitter:card" content="summary_large_image">
<link rel="icon" href="/favicon.svg">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400;500;600;700&family=Geist+Mono&display=swap">
<style>${styles}</style>
${(o.jsonLD ?? []).map((data) => `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, "\\u003c")}</script>`).join("\n")}
</head>
<body>
<main>
${o.body}
  <footer><a href="/">Parallex</a><a href="/apps">Every app</a><a href="/how-it-works">How it works</a><a href="/compatibility">Compatibility</a><a href="/privacy">Privacy</a><a href="https://github.com/mandipadk/parallex">Source</a></footer>
</main>
</body>
</html>
`
}

/** For visitors who have Parallex: New Instance with the app picked. */
const makeLink = (guide: Guide) => {
  const ref = guide.appRef === undefined ? guide.app : guide.appRef
  if (!ref) return ""
  return `  <section class="install">
    <h2>Already have Parallex?</h2>
    <p>This opens New Instance with ${escape(guide.app)} picked; you name it and choose its color.</p>
    <a class="cta" href="parallex://new?app=${encodeURIComponent(ref)}">Make a second ${escape(guide.app)}</a>
  </section>`
}

const installBlock = (app: string) => `  <section class="install">
    <h2>Get Parallex</h2>
    <p>Free and open source, for macOS 14 and later. In Terminal:</p>
    <pre><code>${INSTALL}</code></pre>
    <p>Or <a href="${RELEASES}">download it from GitHub</a>, or with Homebrew: <code>brew tap mandipadk/parallex https://github.com/mandipadk/parallex</code> then <code>brew install --cask parallex</code>. Then choose New Instance, pick ${escape(app)}, and give it a name.</p>
  </section>`

/** An app's history with the latest night in it: the history is kept
 *  hourly, so for a while after a run it doesn't have that night yet. */
function withLatest(nights: LabHistory[string] | undefined, day: string, result: LabResult): LabHistory[string] {
  const kept = nights ?? []
  if (kept.some((n) => n.day === day)) return kept
  return [{ day, version: result.version ?? "", result: result.result }, ...kept].sort((a, b) => b.day.localeCompare(a.day))
}

/**
 * What the lab says about the app, from its latest run and history, or
 * nothing. The page is built with it, and the site's worker renders it
 * again with the newest results each time the page is served (see
 * worker/apppages.ts), so the two always read the same.
 */
export function labBlock(guide: Guide, lab: LabRun | null, history: LabHistory | null): string {
  if (!lab || !guide.labName) return ""
  const result = lab.apps.find((a) => a.app === guide.labName)
  if (!result) return ""
  const date = new Date(lab.date)
  if (Number.isNaN(date.getTime())) return ""
  const day = date.toLocaleDateString("en-US", { month: "long", day: "numeric", year: "numeric", timeZone: "UTC" })
  const version = result.version ? ` ${result.version}` : ""
  if (result.result === "ran") {
    const reached = result.leaks ? `, though it reached ${result.leaks} of the original's files` : ", and nothing reached the original's data"
    const past = history ? historyLine(withLatest(history[guide.labName], lab.date.slice(0, 10), result)) : ""
    return `  <section class="lab">
    <h2>Tested every night</h2>
    <p>Parallex's compatibility lab makes a fresh copy of ${escape(guide.app)}${escape(version)} every night on a clean Mac and opens it. On ${day}, on macOS ${escape(lab.macos)}, the copy ran${reached}.${past ? ` ${escape(past)}` : ""} <a href="/compatibility">See every app's latest result</a>.</p>
  </section>`
  }
  return `  <section class="lab not">
    <h2>Tested every night</h2>
    <p>Parallex's compatibility lab makes a fresh copy of ${escape(guide.app)}${escape(version)} every night on a clean Mac. On ${day} it didn't run cleanly (${escape(result.result)}); <a href="/compatibility">see the latest</a> before relying on it.</p>
  </section>`
}

/** Where the lab's block goes on an app's page: an element of its own that
 *  takes no space, there whether or not the build had results to put in it. */
export const LAB_SLOT_ID = "lab"
/** What goes inside the slot, for a block from labBlock. */
export const labSlotContent = (block: string) => `\n${block}\n  `
const labSlot = (block: string) => `  <div id="${LAB_SLOT_ID}" class="lab-slot">${labSlotContent(block)}</div>`

export function guidePage(guide: Guide, all: Guide[], lab: LabRun | null, history: LabHistory | null = null): string {
  const path = `/apps/${guide.slug}`
  const related = guide.related.map((slug) => all.find((g) => g.slug === slug)).filter((g): g is Guide => Boolean(g))
  const body = `  <a class="back" href="/apps">← Every app</a>

  <header style="display:grid;gap:14px">
    <h1>${escape(guide.title)}</h1>
    <p class="lede">${inline(guide.why)}</p>
  </header>

  <section>
    <h2>How</h2>
    <ol>
      <li><b>Install Parallex</b> (below). Your ${escape(guide.app)} isn't changed.</li>
      <li><b>Choose New Instance and pick ${escape(guide.app)}.</b> Name it for what it's for, like “${escape(guide.app)} Work”, and give it a color.</li>
      <li><b>Open it and sign in</b> with the other account. Both run at once, each in its own windows${guide.ownDock === false ? ", outlined in the instance's color" : ", each with its own Dock icon"}.</li>
    </ol>
  </section>

  <figure>
    <img src="/shots/main.webp" alt="Parallex's main window, listing instances of several apps, each with its own color and name" width="1600" height="1000" loading="lazy">
    <figcaption>Each instance gets its own name and color, so you always know which one you're in.</figcaption>
  </figure>

  <section>
    <h2>What you get with ${escape(guide.app)}</h2>
    <ul>
${guide.specifics.map((s) => `      <li>${inline(s)}</li>`).join("\n")}
    </ul>
  </section>

${labSlot(labBlock(guide, lab, history))}

${guide.limits.length ? `  <section>
    <h2>Good to know</h2>
    <ul>
${guide.limits.map((s) => `      <li>${inline(s)}</li>`).join("\n")}
    </ul>
  </section>` : ""}

  <section class="qa">
    <h2>Questions</h2>
${guide.questions.map((qa) => `    <div><h3>${escape(qa.q)}</h3><p>${inline(qa.a)}</p></div>`).join("\n")}
  </section>

${installBlock(guide.app)}

${makeLink(guide)}

${related.length ? `  <section>
    <h2>Also</h2>
    <div class="grid">
${related.map((g) => `      <a href="/apps/${g.slug}"><b>${escape(g.app)}</b><span>${escape(g.title)}</span></a>`).join("\n")}
    </div>
  </section>` : ""}`
  const faq = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: guide.questions.map((qa) => ({ "@type": "Question", name: qa.q, acceptedAnswer: { "@type": "Answer", text: qa.a.replace(/`/g, "") } })),
  }
  const howTo = {
    "@context": "https://schema.org",
    "@type": "HowTo",
    name: guide.title,
    step: [
      { "@type": "HowToStep", text: `Install Parallex: ${INSTALL}` },
      { "@type": "HowToStep", text: `In Parallex, choose New Instance, pick ${guide.app}, and name it.` },
      { "@type": "HowToStep", text: "Open the new instance and sign in with the other account." },
    ],
  }
  return shell({ title: `${guide.title} · Parallex`, description: guide.description, path, body, jsonLD: [faq, howTo] })
}

export function indexPage(all: Guide[]): string {
  const body = `  <a class="back" href="/">← Parallex</a>

  <header style="display:grid;gap:14px">
    <h1>Run any Mac app twice</h1>
    <p class="lede">Two accounts, side by side, each with its own sign-in, data, notifications and Dock icon. Here's how it goes with the apps people ask about most; most other apps work the same way (Apple's own apps are the exception).</p>
  </header>

  <div class="grid">
${all.map((g) => `    <a href="/apps/${g.slug}"><b>${escape(g.app)}</b><span>${escape(g.title)}</span></a>`).join("\n")}
  </div>

${installBlock("the app")}`
  return shell({
    title: "Run any Mac app twice: two accounts, side by side · Parallex",
    description: "Two Slack, WhatsApp, Discord, Claude or Chrome accounts on one Mac, each with its own sign-in and data. Free and open source.",
    path: "/apps",
    body,
  })
}

export function sitemap(all: Guide[], pages: string[]): string {
  const urls = [...pages, "/apps", ...all.map((g) => `/apps/${g.slug}`)]
  return `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls.map((u) => `  <url><loc>${SITE}${u}</loc></url>`).join("\n")}
</urlset>
`
}

export const robots = `User-agent: *
Disallow: /admin
Disallow: /api/
Sitemap: ${SITE}/sitemap.xml
`
