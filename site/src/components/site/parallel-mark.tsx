import { cn } from "@/lib/utils"

/**
 * The Parallex mark: the original (grey outline, up-left) and its copy
 * (solid vermilion, down-right). Geometry mirrors the app's ParallelMark.
 */
export function ParallelMark({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 64 64" aria-hidden="true" className={cn("size-6", className)}>
      <rect
        x="1.1"
        y="1.1"
        width="37.5"
        height="37.5"
        rx="9.2"
        fill="none"
        stroke="currentColor"
        strokeOpacity="0.45"
        strokeWidth="2.2"
      />
      <rect x="24.3" y="24.3" width="39.7" height="39.7" rx="10.3" fill="var(--brand)" />
    </svg>
  )
}
