import { useEffect, useRef, useState } from "react"
import { AnimatePresence, motion, useInView, useReducedMotion } from "motion/react"
import { Globe, Mail, MessageCircle, Music, SquareCode } from "lucide-react"
import { EASE } from "@/lib/site"
import { AppTile, type Ring } from "../app-tile"

type DockApp = { icon: typeof Mail; ring?: Ring; badge?: string; name?: string; tone?: number }

const apps: DockApp[] = [
  { icon: Mail, tone: 0.3 },
  { icon: Globe, tone: 0.25 },
  { icon: MessageCircle, ring: "brand", badge: "W", name: "Work" },
  { icon: MessageCircle, ring: "light", badge: "P", name: "Personal" },
  { icon: SquareCode, ring: "brand", badge: "C", name: "Client", tone: 0.22 },
  { icon: Music, tone: 0.32 },
]

const named = apps.flatMap((a, i) => (a.name ? [i] : []))

/** A Dock where each copy wears its own ring and badge; a label hops between them. */
export function DockVisual() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { margin: "-20% 0px" })
  const reduce = useReducedMotion()
  const [step, setStep] = useState(0)

  useEffect(() => {
    if (!inView || reduce) return
    const id = setInterval(() => setStep((s) => (s + 1) % named.length), 1800)
    return () => clearInterval(id)
  }, [inView, reduce])

  const active = named[step]

  return (
    <div ref={ref} aria-hidden="true" className="relative grid size-full place-items-center">
      <motion.div
        initial={{ opacity: 0, y: 24 }}
        animate={inView ? { opacity: 1, y: 0 } : undefined}
        transition={{ duration: 0.8, ease: EASE }}
        className="relative mt-10 flex items-end gap-2.5 rounded-[22px] border border-white/10 bg-white/[0.04] p-2.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.06),0_20px_50px_-20px_rgba(0,0,0,0.9)] backdrop-blur-md sm:gap-3 sm:p-3"
      >
        {apps.map((app, i) => {
          const isActive = i === active
          return (
            <motion.div
              key={i}
              initial={{ opacity: 0, y: 10 }}
              animate={inView ? { opacity: 1, y: 0 } : undefined}
              transition={{ duration: 0.5, ease: EASE, delay: 0.15 + i * 0.06 }}
            >
            <motion.div
              className="relative flex flex-col items-center"
              animate={{ y: isActive ? -6 : 0, scale: isActive ? 1.12 : 1 }}
              transition={{ duration: 0.45, ease: EASE }}
              style={{ transformOrigin: "50% 100%" }}
            >
              <AnimatePresence>
                {isActive && app.name && (
                  <motion.span
                    key={app.name}
                    initial={{ opacity: 0, y: 6, filter: "blur(6px)" }}
                    animate={{ opacity: 1, y: 0, filter: "blur(0px)" }}
                    exit={{ opacity: 0, y: 4, filter: "blur(6px)" }}
                    transition={{ duration: 0.35, ease: EASE }}
                    className="absolute -top-11 rounded-lg border border-white/10 bg-popover px-2.5 py-1 text-xs font-medium whitespace-nowrap text-foreground shadow-lg"
                  >
                    {app.name}
                  </motion.span>
                )}
              </AnimatePresence>
              <AppTile
                icon={app.icon}
                size={40}
                ring={app.ring}
                badge={app.badge}
                tone={app.tone}
                className="sm:hidden"
              />
              <AppTile
                icon={app.icon}
                size={48}
                ring={app.ring}
                badge={app.badge}
                tone={app.tone}
                className="max-sm:hidden"
              />
              <span className="absolute -bottom-2 size-1 rounded-full bg-white/50" />
            </motion.div>
            </motion.div>
          )
        })}
      </motion.div>
    </div>
  )
}
