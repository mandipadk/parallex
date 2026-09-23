import type { LucideIcon } from "lucide-react"
import { cn } from "@/lib/utils"

export type Ring = "brand" | "light" | "none"

const ringColor: Record<Ring, string> = {
  brand: "var(--brand)",
  light: "oklch(0.93 0 0)",
  none: "transparent",
}

type AppTileProps = {
  icon: LucideIcon
  size?: number
  ring?: Ring
  badge?: string
  tone?: number
  className?: string
}

/**
 * A generic app icon: neutral squircle with a simple glyph. Copies get a
 * color ring and a small badge, the way Parallex marks them in the Dock.
 */
export function AppTile({ icon: Icon, size = 56, ring = "none", badge, tone = 0.27, className }: AppTileProps) {
  const color = ringColor[ring]
  return (
    <div
      className={cn("relative shrink-0", className)}
      style={{ width: size, height: size }}
    >
      <div
        className="absolute inset-0 grid place-items-center rounded-[24%] border border-white/[0.07] shadow-[inset_0_1px_0_rgba(255,255,255,0.09),0_8px_20px_-8px_rgba(0,0,0,0.8)]"
        style={{
          background: `oklch(${tone} 0 0)`,
          boxShadow:
            ring === "none"
              ? undefined
              : `0 0 0 ${Math.max(2, size * 0.035)}px var(--background), 0 0 0 ${Math.max(3.5, size * 0.07)}px ${color}, inset 0 1px 0 rgba(255,255,255,0.09)`,
        }}
      >
        <Icon strokeWidth={1.6} className="text-white/85" style={{ width: size * 0.44, height: size * 0.44 }} />
      </div>
      {badge && (
        <span
          className="absolute -right-[12%] -bottom-[12%] grid place-items-center rounded-full font-semibold text-[#140a06] ring-2 ring-background"
          style={{
            background: color === "transparent" ? "oklch(0.9 0 0)" : color,
            width: size * 0.4,
            height: size * 0.4,
            fontSize: size * 0.2,
          }}
        >
          {badge}
        </span>
      )}
    </div>
  )
}
