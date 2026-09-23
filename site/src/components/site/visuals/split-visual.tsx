import { useRef } from "react"
import { motion, useInView, useReducedMotion } from "motion/react"
import { MessageCircle } from "lucide-react"
import { AppTile } from "../app-tile"

const DURATION = 6.5
// split, hold, merge, rest
const TIMES = [0, 0.16, 0.8, 0.92, 1]

/** One app tile splits into two copies: Work (vermilion) and Personal (light). */
export function SplitVisual() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { margin: "-20% 0px" })
  const reduce = useReducedMotion()
  const play = inView && !reduce

  // Reduced motion shows the split state; otherwise loop only while visible.
  const loop = (values: number[]) => (reduce ? values[1] : play ? values : values[0])

  const transition = {
    duration: DURATION,
    times: TIMES,
    ease: [0.65, 0, 0.35, 1] as const,
    repeat: Infinity,
    repeatDelay: 0.4,
  }

  const side = (dir: -1 | 1, ring: "brand" | "light", label: string, badge: string) => (
    <motion.div
      className="absolute top-1/2 left-1/2 -mt-[52px] -ml-9 flex flex-col items-center"
      animate={{ x: loop([0, 78 * dir, 78 * dir, 0, 0]) }}
      transition={transition}
    >
      <div className="relative">
        <AppTile icon={MessageCircle} size={72} />
        <motion.div
          className="absolute -inset-[7px] rounded-[30%] border-[2.5px]"
          style={{ borderColor: ring === "brand" ? "var(--brand)" : "oklch(0.93 0 0)" }}
          animate={{ opacity: loop([0, 1, 1, 0, 0]), scale: loop([0.9, 1, 1, 0.9, 0.9]) }}
          transition={transition}
        />
        <motion.span
          className="absolute -right-2.5 -bottom-2.5 grid size-7 place-items-center rounded-full text-[13px] font-semibold text-[#140a06] ring-[3px] ring-card"
          style={{ background: ring === "brand" ? "var(--brand)" : "oklch(0.93 0 0)" }}
          animate={{ opacity: loop([0, 1, 1, 0, 0]), scale: loop([0.4, 1, 1, 0.4, 0.4]) }}
          transition={transition}
        >
          {badge}
        </motion.span>
      </div>
      <motion.span
        className="mt-5 text-sm font-medium text-foreground/90"
        animate={{ opacity: loop([0, 1, 1, 0, 0]), y: loop([-4, 0, 0, -4, -4]) }}
        transition={transition}
      >
        {label}
      </motion.span>
    </motion.div>
  )

  return (
    <div ref={ref} aria-hidden="true" className="relative size-full">
      <motion.div
        className="absolute top-1/2 left-1/2 -mt-20 h-32 w-px bg-white/10"
        animate={{ scaleY: loop([0, 1, 1, 0, 0]), opacity: loop([0, 1, 1, 0, 0]) }}
        transition={transition}
      />
      {side(-1, "brand", "Work", "W")}
      {side(1, "light", "Personal", "P")}
    </div>
  )
}
