import { useEffect, useRef, useState } from "react"
import { motion, useInView, useReducedMotion } from "motion/react"
import { Globe, MessageCircle, SquareCode } from "lucide-react"
import { Kbd } from "@/components/kbd"
import { EASE } from "@/lib/site"
import { AppTile, type Ring } from "../app-tile"

const items: { icon: typeof Globe; name: string; app: string; ring: Ring }[] = [
  { icon: MessageCircle, name: "Work", app: "Chat", ring: "brand" },
  { icon: MessageCircle, name: "Personal", app: "Chat", ring: "light" },
  { icon: SquareCode, name: "Client", app: "Editor", ring: "brand" },
  { icon: Globe, name: "Testing", app: "Browser", ring: "light" },
]

const ROW = 44

/** The ⌃⌥Space switcher: each press moves the selection to the next copy. */
export function SwitcherVisual() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { margin: "-20% 0px" })
  const reduce = useReducedMotion()
  const [index, setIndex] = useState(0)
  const [pressed, setPressed] = useState(false)

  useEffect(() => {
    if (!inView || reduce) return
    let release: ReturnType<typeof setTimeout>
    const id = setInterval(() => {
      setPressed(true)
      setIndex((i) => (i + 1) % items.length)
      release = setTimeout(() => setPressed(false), 180)
    }, 1500)
    return () => {
      clearInterval(id)
      clearTimeout(release)
    }
  }, [inView, reduce])

  return (
    <div ref={ref} aria-hidden="true" className="relative flex size-full flex-col items-center justify-center gap-5">
      <div className="flex items-center gap-1.5 font-mono text-[22px]">
        <Kbd keys={["ctrl"]} active={pressed} />
        <Kbd keys={["option"]} active={pressed} />
        <Kbd keys={[{ display: "Space", key: "space" }]} active={pressed} className="px-[1.4em]" />
      </div>

      <motion.div
        initial={{ opacity: 0, y: 16, scale: 0.97 }}
        animate={inView ? { opacity: 1, y: 0, scale: 1 } : undefined}
        transition={{ duration: 0.7, ease: EASE }}
        className="relative w-[15.5rem] rounded-2xl border border-white/10 bg-popover/80 p-1.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.06),0_24px_60px_-24px_rgba(0,0,0,0.9)] backdrop-blur-xl"
      >
        <motion.div
          className="absolute inset-x-1.5 top-1.5 rounded-[10px] bg-white/[0.08]"
          style={{ height: ROW }}
          animate={{ y: index * ROW }}
          transition={{ type: "spring", stiffness: 520, damping: 40 }}
        />
        {items.map((item, i) => (
          <div key={item.name} className="relative flex items-center gap-3 px-2.5" style={{ height: ROW }}>
            <AppTile icon={item.icon} size={26} ring={item.ring} />
            <span className="text-[13px] font-medium text-foreground">{item.name}</span>
            <span className="ml-auto text-xs text-subtle">{item.app}</span>
            <motion.span
              className="absolute top-1/2 -left-px h-4 w-[3px] -translate-y-1/2 rounded-full bg-brand"
              animate={{ opacity: i === index ? 1 : 0 }}
              transition={{ duration: 0.2 }}
            />
          </div>
        ))}
      </motion.div>
    </div>
  )
}
