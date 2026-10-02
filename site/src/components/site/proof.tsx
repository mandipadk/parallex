import { useEffect, useState } from "react"
import { ArrowUpRight } from "lucide-react"
import { guides } from "../../../guides/apps.ts"
import { Heading } from "./heading"
import { Reveal, RevealGroup, RevealItem } from "./reveal"

type LabApp = { app: string; version?: string; mode?: string; result: string; leaks?: number }
type Lab = { date: string; macos: string; apps: LabApp[] }

/** Last night's lab run, from the site's own API (which reads the published results). */
function useLab(): Lab | null {
  const [lab, setLab] = useState<Lab | null>(null)
  useEffect(() => {
    let current = true
    fetch("/api/v1/compatibility")
      .then((response) => (response.ok ? response.json() : null))
      .then((body: { lab?: Lab | null } | null) => {
        if (current && body?.lab?.apps?.length) setLab(body.lab)
      })
      .catch(() => undefined)
    return () => {
      current = false
    }
  }, [])
  return lab
}

const when = (iso: string) => {
  const hours = (Date.now() - Date.parse(iso)) / 3_600_000
  if (hours < 30) return "Last night"
  return `On ${new Date(iso).toLocaleDateString("en-US", { month: "long", day: "numeric", timeZone: "UTC" })}`
}

function summary(lab: Lab | null): string {
  if (!lab) return "Every night, a clean Mac makes a fresh instance of each of these apps, the way New Instance makes one, opens it, and checks that it runs without reaching the original's data."
  const tried = lab.apps.filter((a) => ["ran", "quit", "crashed", "leaked"].includes(a.result))
  const clean = tried.filter((a) => a.result === "ran" && !a.leaks)
  return `${when(lab.date)}, on macOS ${lab.macos}, ${clean.length} of ${tried.length} instances ran on a clean Mac without reaching the original's data. It happens every night, and the results are public.`
}

const links = [
  { href: "/compatibility", label: "Every result" },
  { href: "/how-it-works", label: "What it does to an app" },
  { href: "https://github.com/mandipadk/parallex", label: "Read the source" },
]

export function Proof() {
  const lab = useLab()
  return (
    <section id="apps" className="mx-auto max-w-6xl px-4 pt-32 sm:px-6 sm:pt-44">
      <Reveal className="mx-auto max-w-2xl text-center">
        <Heading serif="every night.">Tested</Heading>
        <p className="mx-auto mt-6 max-w-xl text-[17px] leading-relaxed text-pretty text-muted-foreground">{summary(lab)}</p>
      </Reveal>

      <RevealGroup className="mt-14 grid grid-cols-2 gap-3 sm:mt-16 sm:grid-cols-3 lg:grid-cols-5" stagger={0.03}>
        {guides.map((guide) => {
          const found = guide.labName ? lab?.apps.find((a) => a.app === guide.labName) : undefined
          // A page about a browser's profile instance shows only that kind's result.
          const result = found && (!guide.labMode || guide.labMode === (found.mode ?? "copy")) ? found : undefined
          const clean = result?.result === "ran" && !result.leaks
          const ran = result?.mode === "wrapper" ? "Ran clean as a separate profile" : "Ran clean"
          return (
            <RevealItem key={guide.slug}>
              <a
                href={`/apps/${guide.slug}`}
                className="group flex h-full flex-col justify-between gap-3 rounded-2xl border border-white/[0.07] bg-card/70 px-4 py-3.5 transition-colors duration-300 hover:border-white/[0.16]"
              >
                <span className="text-[15px] font-medium tracking-tight">{guide.app}</span>
                <span className={`text-[12.5px] ${clean ? "text-foreground/70" : "text-subtle"}`}>
                  {result ? (clean ? `${ran}${result.version ? `, ${result.version}` : ""}` : `Last run: ${result.result}`) : guide.labName ? "Tested nightly" : "How it goes"}
                </span>
              </a>
            </RevealItem>
          )
        })}
      </RevealGroup>

      <Reveal className="mt-8 flex flex-wrap justify-center gap-x-8 gap-y-3 text-[14px]">
        {links.map((link) => (
          <a key={link.href} href={link.href} className="inline-flex items-center gap-1 text-muted-foreground transition-colors hover:text-foreground">
            {link.label}
            <ArrowUpRight className="size-3.5" />
          </a>
        ))}
      </Reveal>
    </section>
  )
}
