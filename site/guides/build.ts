// Writes the search pages into dist/ (run after `vite build`):
//   node --experimental-strip-types guides/build.ts
// The latest nightly lab results come from the lab-results branch; without
// them (offline), pages simply leave the lab out.
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { guides } from "./apps.ts"
import { guidePage, indexPage, robots, sitemap, type LabRun } from "./page.ts"

const dist = join(dirname(fileURLToPath(import.meta.url)), "..", "dist")
const LAB = "https://raw.githubusercontent.com/mandipadk/parallex/lab-results/compat-lab.json"

let lab: LabRun | null = null
try {
  const response = await fetch(LAB, { signal: AbortSignal.timeout(10_000) })
  if (response.ok) lab = (await response.json()) as LabRun
} catch {
  lab = null
}

mkdirSync(join(dist, "apps"), { recursive: true })
for (const guide of guides) {
  writeFileSync(join(dist, "apps", `${guide.slug}.html`), guidePage(guide, guides, lab))
}
writeFileSync(join(dist, "apps.html"), indexPage(guides))
writeFileSync(join(dist, "sitemap.xml"), sitemap(guides, ["/", "/how-it-works", "/compatibility", "/privacy"]))
writeFileSync(join(dist, "robots.txt"), robots)
console.log(`Wrote ${guides.length} app pages${lab ? ` with the lab run of ${lab.date.slice(0, 10)}` : " (no lab results)"}.`)
