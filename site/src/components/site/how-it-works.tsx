import { useEffect, useRef, useState } from "react"
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react"
import { EASE } from "@/lib/site"
import { cn } from "@/lib/utils"
import { Heading } from "./heading"
import { ProductShot } from "./product-shot"
import { Reveal } from "./reveal"

const steps = [
  {
    title: "Pick an app",
    line: "Anything in your Applications folder.",
    shot: "/shots/welcome.webp",
    alt: "Parallex welcome screen: one app with Work and Personal copies beside it.",
  },
  {
    title: "Name it",
    line: "Give it a name, a color and a badge.",
    shot: "/shots/create.webp",
    alt: "Making a new copy: choosing its name, color and badge.",
  },
  {
    title: "Open it",
    line: "From the Dock, the menu bar or a shortcut.",
    shot: "/shots/menubar.webp",
    alt: "The Parallex menu-bar panel listing every copy with its shortcut.",
    kind: "panel" as const,
  },
]

const STEP_MS = 5000

export function HowItWorks() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { margin: "-25% 0px" })
  const reduce = useReducedMotion()
  const [active, setActive] = useState(0)
  const [cycle, setCycle] = useState(0)

  useEffect(() => {
    if (!inView || reduce) return
    const id = setTimeout(() => setActive((a) => (a + 1) % steps.length), STEP_MS)
    return () => clearTimeout(id)
  }, [active, cycle, inView, reduce])

  const select = (i: number) => {
    setActive(i)
    setCycle((c) => c + 1)
  }

  return (
    <section ref={ref} id="how" className="mx-auto max-w-6xl px-4 pt-32 sm:px-6 sm:pt-44">
      <Reveal className="mx-auto max-w-2xl text-center">
        <Heading serif="That's it.">Three steps.</Heading>
      </Reveal>

      <Reveal delay={0.1} className="mt-14 grid items-center gap-8 sm:mt-20 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,2fr)] lg:gap-14">
        <ol className="grid gap-2 max-lg:grid-cols-3 max-sm:grid-cols-1">
          {steps.map((s, i) => (
            <li key={s.title}>
              <button
                type="button"
                onClick={() => select(i)}
                aria-pressed={i === active}
                className={cn(
                  "relative w-full overflow-hidden rounded-2xl px-5 py-4 text-left transition-colors duration-300",
                  i === active ? "bg-white/[0.05]" : "hover:bg-white/[0.025]",
                )}
              >
                <div className="flex items-baseline gap-3">
                  <span className={cn("font-mono text-[13px] transition-colors", i === active ? "text-brand" : "text-subtle")}>
                    {i + 1}
                  </span>
                  <span className={cn("text-lg font-semibold tracking-tight transition-colors", i === active ? "text-foreground" : "text-foreground/55")}>
                    {s.title}
                  </span>
                </div>
                <p className={cn("mt-1 pl-[1.4rem] text-sm text-muted-foreground transition-opacity duration-300", i === active ? "opacity-100" : "opacity-60")}>
                  {s.line}
                </p>
                {i === active && inView && !reduce && (
                  <motion.span
                    key={`${active}-${cycle}`}
                    className="absolute bottom-0 left-5 h-px origin-left bg-brand/70"
                    style={{ right: "1.25rem" }}
                    initial={{ scaleX: 0 }}
                    animate={{ scaleX: 1 }}
                    transition={{ duration: STEP_MS / 1000, ease: "linear" }}
                  />
                )}
              </button>
            </li>
          ))}
        </ol>

        <div className="relative">
          <AnimatePresence mode="popLayout" initial={false}>
            <motion.div
              key={active}
              initial={{ opacity: 0, y: 12, filter: "blur(8px)" }}
              animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
              exit={{ opacity: 0, y: -8, filter: "blur(8px)" }}
              transition={{ duration: 0.5, ease: EASE }}
            >
              <ProductShot src={steps[active].shot} alt={steps[active].alt} kind={steps[active].kind} />
            </motion.div>
          </AnimatePresence>
        </div>
      </Reveal>
    </section>
  )
}
