import { lazy, Suspense, useEffect, useState } from "react"
import { motion, useReducedMotion } from "motion/react"
import { cn } from "@/lib/utils"

// three.js is heavy; load the rays after first paint so text lands instantly.
const LightRays = lazy(() => import("@/components/light-rays"))

type RaysProps = {
  className?: string
  intensity?: number
  reach?: number
  /** Delay before the rays fade in, in seconds. */
  delay?: number
  /** Overall strength of the layer, 0 to 1. */
  strength?: number
}

/**
 * Spell UI light rays, retinted for Parallex: warm white with a faint
 * vermilion second beam. No blue, no violet.
 */
export function Rays({ className, intensity = 13, reach = 16, delay = 0.2, strength = 0.8 }: RaysProps) {
  const reduce = useReducedMotion()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    const id = requestAnimationFrame(() => setReady(true))
    return () => cancelAnimationFrame(id)
  }, [])

  return (
    <motion.div
      aria-hidden="true"
      className={cn(
        "pointer-events-none absolute inset-0 -z-10",
        "[mask-image:linear-gradient(to_bottom,black_50%,transparent)]",
        className,
      )}
      initial={{ opacity: 0 }}
      animate={{ opacity: ready ? strength : 0 }}
      transition={{ duration: 2.2, ease: "easeOut", delay }}
    >
      {ready && (
        <Suspense fallback={null}>
          <LightRays
            backgroundColor="transparent"
            style={{ zIndex: 0 }}
            intensity={intensity}
            rays={32}
            reach={reach}
            position={50}
            animation={{ animate: !reduce, speed: 8 }}
            raysColor={{ mode: "multi", color1: "#FFF3EC", color2: "#FFB89E" }}
          />
        </Suspense>
      )}
    </motion.div>
  )
}
