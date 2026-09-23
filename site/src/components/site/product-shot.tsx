import { useState } from "react"
import { Globe, MessageCircle, SquareCode } from "lucide-react"
import { cn } from "@/lib/utils"
import { AppTile } from "./app-tile"

type ShotProps = {
  src: string
  alt: string
  /** "window": a full macOS window with its own chrome and transparent corners.
   *  "panel": a square-cornered crop (the menu-bar panel), shown on a stage. */
  kind?: "window" | "panel"
  className?: string
  priority?: boolean
}

// The window captures are 1960x1320 (@2x); keep that exact frame.
const WINDOW_ASPECT = "aspect-[1960/1320]"

/**
 * A real product screenshot with a soft, alpha-aware shadow. If the image is
 * missing, a neutral sketch of the Parallex window stands in.
 */
export function ProductShot({ src, alt, kind = "window", className, priority }: ShotProps) {
  const [state, setState] = useState<"loading" | "ok" | "missing">("loading")

  const img = state !== "missing" && (
    <img
      src={src}
      alt={alt}
      loading={priority ? "eager" : "lazy"}
      decoding="async"
      onLoad={() => setState("ok")}
      onError={() => setState("missing")}
      className={cn(
        "transition-opacity duration-700",
        kind === "window"
          ? "absolute inset-0 size-full object-contain drop-shadow-[0_24px_48px_rgba(0,0,0,0.45)]"
          : "h-[82%] w-auto rounded-[14px] shadow-[0_0_0_1px_rgba(255,255,255,0.08),0_30px_60px_-10px_rgba(0,0,0,0.7)]",
        state === "ok" ? "opacity-100" : "opacity-0",
      )}
    />
  )

  if (kind === "panel") {
    return (
      <div
        className={cn(
          "relative grid place-items-center overflow-hidden rounded-[20px] border border-white/[0.07] bg-card/60",
          WINDOW_ASPECT,
          className,
        )}
      >
        {state === "missing" && <WindowSketch framed />}
        {img}
      </div>
    )
  }

  return (
    <div className={cn("relative", WINDOW_ASPECT, className)}>
      {state === "missing" && <WindowSketch framed />}
      {img}
    </div>
  )
}

const rows = [
  { icon: MessageCircle, name: "Work", ring: "brand" as const, active: true },
  { icon: MessageCircle, name: "Personal", ring: "light" as const },
  { icon: SquareCode, name: "Client", ring: "light" as const },
  { icon: Globe, name: "Testing", ring: "none" as const },
]

function WindowSketch({ framed }: { framed?: boolean }) {
  return (
    <div
      aria-hidden="true"
      className={cn(
        "absolute inset-0 flex overflow-hidden text-[clamp(8px,1.1vw,13px)]",
        framed && "rounded-[14px] border border-white/10 bg-card shadow-[0_30px_60px_-10px_rgba(0,0,0,0.7)]",
      )}
    >
      <div className="flex w-[30%] flex-col gap-[0.9em] border-r border-white/[0.06] bg-white/[0.02] p-[1.4em]">
        <div className="mb-[0.8em] flex gap-[0.5em]">
          {[0, 1, 2].map((i) => (
            <span key={i} className="size-[0.9em] rounded-full bg-white/15" />
          ))}
        </div>
        {rows.map((r) => (
          <div
            key={r.name}
            className={cn(
              "flex items-center gap-[0.8em] rounded-[0.7em] px-[0.6em] py-[0.5em]",
              r.active && "bg-white/[0.06]",
            )}
          >
            <AppTile icon={r.icon} size={22} ring={r.ring} className="scale-[0.9] max-sm:hidden" />
            <span className="text-white/70">{r.name}</span>
          </div>
        ))}
      </div>
      <div className="flex flex-1 flex-col items-center justify-center gap-[1.2em]">
        <AppTile icon={MessageCircle} size={64} ring="brand" badge="W" className="max-sm:scale-75" />
        <div className="text-[1.6em] font-semibold tracking-tight text-white/85">Work</div>
        <div className="flex w-[52%] flex-col gap-[0.7em]">
          {[70, 88, 56].map((w) => (
            <div key={w} className="h-[0.7em] rounded-full bg-white/[0.06]" style={{ width: `${w}%` }} />
          ))}
        </div>
      </div>
    </div>
  )
}
