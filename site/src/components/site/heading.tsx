import type { ReactNode } from "react"
import { cn } from "@/lib/utils"

/** Section headline: Geist semibold, tight, with one Instrument Serif italic phrase. */
export function Heading({ children, serif, className }: { children: ReactNode; serif: ReactNode; className?: string }) {
  return (
    <h2 className={cn("text-[clamp(2.25rem,5.2vw,3.75rem)] leading-[1] font-semibold tracking-tighter text-balance", className)}>
      {children} <span className="serif-word">{serif}</span>
    </h2>
  )
}
