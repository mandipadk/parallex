import { motion } from "motion/react"
import { BlurReveal } from "@/components/blur-reveal"
import { EASE, riseIn } from "@/lib/site"
import { DownloadButton } from "./download-button"
import { ProductShot } from "./product-shot"
import { Rays } from "./rays"

export function Hero() {
  return (
    <section id="top" className="relative isolate overflow-hidden pt-32 sm:pt-40">
      <Rays className="h-[min(1100px,120svh)]" intensity={12} reach={6} />

      <div className="mx-auto flex max-w-6xl flex-col items-center px-4 text-center sm:px-6">
        <h1 className="text-[clamp(3.25rem,10vw,7.25rem)] leading-[0.92] font-semibold tracking-tighter text-balance">
          <BlurReveal as="span" className="inline-block" delay={0.15} speedReveal={1.4}>
            Every app.
          </BlurReveal>{" "}
          <BlurReveal as="span" className="serif-word inline-block pr-[0.06em]" delay={0.5} speedReveal={1.2}>
            Twice.
          </BlurReveal>
        </h1>

        <motion.p
          initial="hidden"
          animate="visible"
          variants={riseIn}
          transition={{ duration: 0.7, ease: EASE, delay: 0.85 }}
          className="mt-6 max-w-[34rem] text-[17px] leading-relaxed text-pretty text-foreground/70 sm:text-lg"
        >
          Run separate copies of any Mac app, each with its own accounts, data and Dock icon.
        </motion.p>

        <motion.div
          initial="hidden"
          animate="visible"
          variants={riseIn}
          transition={{ duration: 0.7, ease: EASE, delay: 1.0 }}
          className="mt-9 flex flex-col items-center gap-4"
        >
          <DownloadButton />
          <p className="text-[13px] text-foreground/45">Free · Open source · macOS 14+</p>
        </motion.div>
      </div>

      <div className="mx-auto mt-16 max-w-6xl px-4 [perspective:1600px] sm:mt-20 sm:px-6">
        <motion.div
          initial={{ opacity: 0, y: 80, rotateX: 14, scale: 0.96 }}
          animate={{ opacity: 1, y: 0, rotateX: 0, scale: 1 }}
          transition={{ duration: 1.4, ease: EASE, delay: 1.1 }}
          style={{ transformOrigin: "50% 0%" }}
        >
          <ProductShot
            priority
            src="/shots/main.webp"
            alt="The Parallex window listing copies of several apps, with Claude Work selected."
          />
        </motion.div>
      </div>
    </section>
  )
}
