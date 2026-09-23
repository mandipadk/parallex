import { ArrowDown } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DOWNLOAD_URL } from "@/lib/site"
import { cn } from "@/lib/utils"

/** The one primary action on the page. */
export function DownloadButton({ size = "lg", className }: { size?: "sm" | "lg"; className?: string }) {
  return (
    <Button
      asChild
      className={cn(
        "group/dl rounded-full bg-primary font-medium text-primary-foreground transition-[transform,box-shadow,background-color] duration-300 ease-out-soft hover:-translate-y-px hover:bg-white hover:shadow-[0_10px_40px_-8px_rgba(255,107,61,0.45)] active:translate-y-0",
        size === "lg" ? "h-12 gap-2 px-6 text-[15px]" : "h-8 gap-1.5 px-3.5 text-[13px]",
        className,
      )}
    >
      <a href={DOWNLOAD_URL}>
        {size === "lg" ? "Download for Mac" : "Download"}
        <span
          className={cn(
            "grid place-items-center overflow-hidden rounded-full bg-primary-foreground/[0.08]",
            size === "lg" ? "size-6" : "size-4",
          )}
        >
          <ArrowDown
            strokeWidth={2.2}
            className={cn(
              "transition-transform duration-300 ease-out-soft group-hover/dl:translate-y-0.5",
              size === "lg" ? "size-3.5!" : "size-3!",
            )}
          />
        </span>
      </a>
    </Button>
  )
}
