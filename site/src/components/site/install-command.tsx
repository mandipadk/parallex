import { Check, Copy } from "lucide-react"
import { useState } from "react"
import { cn } from "@/lib/utils"

export const INSTALL_COMMAND = "curl -fsSL https://parallex.mandip.dev/install | sh"

/** The Terminal alternative to the download: no "Open Anyway" step. */
export function InstallCommand({ className }: { className?: string }) {
  const [copied, setCopied] = useState(false)

  async function copy() {
    try {
      await navigator.clipboard.writeText(INSTALL_COMMAND)
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    } catch {
      // Clipboard refused: the command stays selectable.
    }
  }

  return (
    // Hidden on phones, where there's no Terminal to paste it into.
    <div className={cn("hidden w-full max-w-md flex-col items-center gap-2 sm:flex", className)}>
      <p className="text-[13px] text-foreground/45">or in Terminal</p>
      <div className="flex max-w-full min-w-0 items-center gap-1 rounded-full border border-white/[0.08] bg-card/60 py-1 pr-1 pl-4 backdrop-blur-sm">
        <code className="min-w-0 truncate font-mono text-[12.5px] text-foreground/75 select-all">{INSTALL_COMMAND}</code>
        <button
          type="button"
          onClick={copy}
          aria-label={copied ? "Copied" : "Copy the install command"}
          className="grid size-7 shrink-0 place-items-center rounded-full text-foreground/55 transition-colors hover:bg-white/[0.06] hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring/60 focus-visible:outline-none"
        >
          {copied ? <Check className="size-3.5" strokeWidth={2.2} /> : <Copy className="size-3.5" strokeWidth={2} />}
        </button>
      </div>
    </div>
  )
}
