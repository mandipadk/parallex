import type { ReactNode } from "react"
import { Globe, Keyboard, Layers, RefreshCw } from "lucide-react"
import { Heading } from "./heading"
import { Reveal, RevealGroup, RevealItem } from "./reveal"
import { DockVisual } from "./visuals/dock-visual"
import { LinkVisual } from "./visuals/link-visual"
import { SplitVisual } from "./visuals/split-visual"
import { SwitcherVisual } from "./visuals/switcher-visual"

const beats: { title: string; serif: string; line: ReactNode; visual: ReactNode }[] = [
  {
    title: "Separate",
    serif: "by default.",
    line: "Every copy has its own sign-in and data, App Store apps included. Nothing leaks across.",
    visual: <SplitVisual />,
  },
  {
    title: "Always know",
    serif: "which one.",
    line: "Each copy gets its own name, Dock icon, color ring and badge.",
    visual: <DockVisual />,
  },
  {
    title: "Links land",
    serif: "where they should.",
    line: "Sign-in links reach the right copy, and web links open in that copy's browser.",
    visual: <LinkVisual />,
  },
  {
    title: "Switch in",
    serif: "a keystroke.",
    line: "Press ⌃⌥Space to see every copy. Pick one and keep going.",
    visual: <SwitcherVisual />,
  },
]

const extras = [
  { icon: Layers, label: "Workspaces that open together" },
  { icon: Keyboard, label: "A shortcut for every copy" },
  { icon: Globe, label: "Any website as an app" },
  { icon: RefreshCw, label: "Updates itself, safely" },
]

export function Features() {
  return (
    <section id="features" className="mx-auto max-w-6xl px-4 pt-32 sm:px-6 sm:pt-44">
      <Reveal className="mx-auto max-w-2xl text-center">
        <Heading serif="apart.">Built to keep things</Heading>
      </Reveal>

      <RevealGroup className="mt-14 grid gap-4 sm:mt-20 md:grid-cols-2" stagger={0.1}>
        {beats.map((b) => (
          <RevealItem
            key={b.title}
            className="group relative overflow-hidden rounded-[28px] border border-white/[0.07] bg-card/70 transition-colors duration-500 hover:border-white/[0.12]"
          >
            <div className="h-64 sm:h-72">{b.visual}</div>
            <div className="px-7 pt-2 pb-8 sm:px-9 sm:pb-9">
              <h3 className="text-[26px] leading-tight font-semibold tracking-tighter sm:text-[28px]">
                {b.title} <span className="serif-word">{b.serif}</span>
              </h3>
              <p className="mt-2 text-[15px] leading-relaxed text-pretty text-muted-foreground">{b.line}</p>
            </div>
          </RevealItem>
        ))}
      </RevealGroup>

      <RevealGroup className="mt-4 grid grid-cols-2 gap-4 lg:grid-cols-4" stagger={0.06}>
        {extras.map(({ icon: Icon, label }) => (
          <RevealItem
            key={label}
            className="flex items-center gap-3 rounded-2xl border border-white/[0.07] bg-card/40 px-4 py-4 text-sm text-foreground/85 sm:px-5"
          >
            <Icon className="size-[18px] shrink-0 text-subtle" strokeWidth={1.75} />
            {label}
          </RevealItem>
        ))}
      </RevealGroup>
    </section>
  )
}
