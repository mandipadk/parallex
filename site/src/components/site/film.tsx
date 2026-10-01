import { useEffect, useRef } from "react"
import { useReducedMotion } from "motion/react"
import { Heading } from "./heading"
import { Reveal } from "./reveal"

/**
 * The half-minute film, made from the app's real screens. It's silent, so it
 * plays muted while it's on screen and pauses when it isn't; with reduced
 * motion it waits for a click.
 */
export function Film() {
  const video = useRef<HTMLVideoElement>(null)
  const reduced = useReducedMotion()

  useEffect(() => {
    const element = video.current
    if (!element || reduced) return
    const watcher = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) element.play().catch(() => undefined)
        else element.pause()
      },
      { threshold: 0.5 },
    )
    watcher.observe(element)
    return () => watcher.disconnect()
  }, [reduced])

  return (
    <section id="film" className="mx-auto max-w-6xl px-4 pt-32 sm:px-6 sm:pt-44">
      <Reveal className="mx-auto max-w-2xl text-center">
        <Heading serif="half a minute.">Parallex in</Heading>
      </Reveal>
      <Reveal className="mt-12 sm:mt-14">
        <video
          ref={video}
          src="/video/parallex.mp4"
          poster="/video/poster.jpg"
          width={1280}
          height={720}
          muted
          loop
          playsInline
          preload="none"
          controls={!!reduced}
          aria-label="A 28-second film: two copies of Claude signed in to two accounts, making a copy of Cursor with its own Dock icon, a sign-in link reaching the right copy, and last night's lab results."
          className="aspect-video w-full rounded-[20px] border border-white/[0.07] bg-card"
        />
      </Reveal>
    </section>
  )
}
