import { useRef } from "react"
import { motion, useInView, useReducedMotion } from "motion/react"
import { Check, Link2 } from "lucide-react"

const DURATION = 5.5
const T = [0, 0.12, 0.42, 0.52, 0.86, 1]

/** A sign-in link travels to the copy you used last, which lights up. */
export function LinkVisual() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { margin: "-20% 0px" })
  const reduce = useReducedMotion()
  const play = inView && !reduce

  // Timeline: chip pulses, path draws, window lights up, hold, reset.
  const at = <V,>(values: V[]) => (reduce ? values[3] : play ? values : values[0])
  const transition = { duration: DURATION, times: T, ease: "easeInOut" as const, repeat: Infinity }

  return (
    <div ref={ref} aria-hidden="true" className="relative flex size-full items-center justify-center px-5 sm:px-8">
      <div className="flex w-full max-w-[26rem] items-center">
        {/* The link, as it arrives in a message */}
        <div className="w-[42%] shrink-0 rounded-2xl border border-white/10 bg-white/[0.04] p-3 sm:p-3.5">
          <div className="h-1.5 w-3/4 rounded-full bg-white/10" />
          <div className="mt-2 h-1.5 w-1/2 rounded-full bg-white/10" />
          <motion.div
            className="mt-3 inline-flex items-center gap-1.5 rounded-lg bg-white/[0.08] px-2 py-1.5 text-[11px] font-medium whitespace-nowrap text-foreground sm:text-xs"
            animate={{ scale: at([1, 0.94, 1, 1, 1, 1]) }}
            transition={transition}
          >
            <Link2 className="size-3.5 text-brand" strokeWidth={2} />
            Sign in
          </motion.div>
        </div>

        {/* Route */}
        <svg viewBox="0 0 100 100" preserveAspectRatio="none" className="h-36 min-w-0 flex-1 overflow-visible">
          <path d="M0 62 C 50 62, 50 24, 100 24" fill="none" stroke="rgba(255,255,255,0.08)" strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
          <path d="M0 62 C 50 62, 50 77, 100 77" fill="none" stroke="rgba(255,255,255,0.08)" strokeWidth="1.5" strokeDasharray="3 4" vectorEffect="non-scaling-stroke" />
          <motion.path
            d="M0 62 C 50 62, 50 24, 100 24"
            fill="none"
            stroke="var(--brand)"
            strokeWidth="1.75"
            strokeLinecap="round"
            vectorEffect="non-scaling-stroke"
            animate={{ pathLength: at([0, 0, 1, 1, 1, 0]), opacity: at([0, 1, 1, 1, 1, 0]) }}
            transition={transition}
          />
        </svg>

        {/* The two copies */}
        <div className="flex w-[38%] shrink-0 flex-col gap-3">
          <motion.div
            className="relative rounded-xl border bg-white/[0.04] p-2.5"
            animate={{
              borderColor: at([
                "rgba(255,255,255,0.1)",
                "rgba(255,255,255,0.1)",
                "rgba(255,255,255,0.1)",
                "rgba(255,107,61,0.9)",
                "rgba(255,107,61,0.9)",
                "rgba(255,255,255,0.1)",
              ]),
            }}
            transition={transition}
          >
            <WindowTitle name="Work" dot="var(--brand)" />
            <div className="mt-2 flex items-center justify-between">
              <span className="text-[10px] text-subtle sm:text-[11px]">Last used</span>
              <motion.span
                className="grid size-4 place-items-center rounded-full bg-brand text-[#140a06]"
                animate={{ scale: at([0, 0, 0, 1, 1, 0]), opacity: at([0, 0, 0, 1, 1, 0]) }}
                transition={transition}
              >
                <Check className="size-2.5" strokeWidth={3} />
              </motion.span>
            </div>
          </motion.div>
          <div className="rounded-xl border border-white/10 bg-white/[0.02] p-2.5 opacity-60">
            <WindowTitle name="Personal" dot="oklch(0.93 0 0)" />
            <div className="mt-2 h-1.5 w-2/3 rounded-full bg-white/10" />
          </div>
        </div>
      </div>
    </div>
  )
}

function WindowTitle({ name, dot }: { name: string; dot: string }) {
  return (
    <div className="flex items-center gap-1.5">
      <span className="size-2 rounded-full" style={{ background: dot }} />
      <span className="text-xs font-medium text-foreground/90">{name}</span>
    </div>
  )
}
