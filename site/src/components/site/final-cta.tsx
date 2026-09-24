import { KOFI_URL, SPONSOR_URL } from "@/lib/site"
import { DownloadButton } from "./download-button"
import { Heading } from "./heading"
import { ParallelMark } from "./parallel-mark"
import { Rays } from "./rays"
import { Reveal, RevealGroup, RevealItem } from "./reveal"

/** Closing stage: the rays again, framed like the component's own demo canvas. */
export function FinalCta() {
  return (
    <section className="mx-auto max-w-6xl px-4 pt-32 pb-24 sm:px-6 sm:pt-44 sm:pb-32">
      <Reveal className="relative isolate overflow-hidden rounded-[32px] border border-white/[0.08] sm:rounded-[40px]">
        <Rays intensity={9} reach={12} delay={0} />
        <RevealGroup className="flex flex-col items-center px-6 pt-24 pb-20 text-center sm:pt-32 sm:pb-28" stagger={0.1}>
          <RevealItem>
            <ParallelMark className="size-14" />
          </RevealItem>
          <RevealItem className="mt-8">
            <Heading serif="a second one?" className="text-[clamp(2.5rem,6vw,4.5rem)]">
              Ready for
            </Heading>
          </RevealItem>
          <RevealItem>
            <p className="mt-5 text-[17px] text-muted-foreground">Free and open source. Apple silicon and Intel.</p>
          </RevealItem>
          <RevealItem className="mt-9 flex flex-col items-center gap-4">
            <DownloadButton />
            <p className="text-[13px] text-subtle">Requires macOS 14 or later</p>
          </RevealItem>
          <RevealItem>
            <p className="mt-10 max-w-md text-[14px] leading-relaxed text-pretty text-muted-foreground">
              Parallex is free and made by a student. If it saves you a subscription,{" "}
              <a className="text-foreground underline decoration-white/25 underline-offset-4 transition-colors hover:decoration-white/60" href={SPONSOR_URL}>
                sponsor it
              </a>{" "}
              or{" "}
              <a className="text-foreground underline decoration-white/25 underline-offset-4 transition-colors hover:decoration-white/60" href={KOFI_URL}>
                buy it a coffee
              </a>
              . First goal: signing it with Apple, so it opens without “Open Anyway”.
            </p>
          </RevealItem>
        </RevealGroup>
      </Reveal>
    </section>
  )
}
