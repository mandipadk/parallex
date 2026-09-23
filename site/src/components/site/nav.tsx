import { useEffect, useState } from "react"
import { motion } from "motion/react"
import { REPO_URL, EASE } from "@/lib/site"
import { cn } from "@/lib/utils"
import { DownloadButton } from "./download-button"
import { GitHubMark } from "./icons"
import { ParallelMark } from "./parallel-mark"

export function Nav() {
  const [scrolled, setScrolled] = useState(false)

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12)
    onScroll()
    window.addEventListener("scroll", onScroll, { passive: true })
    return () => window.removeEventListener("scroll", onScroll)
  }, [])

  return (
    <motion.header
      initial={{ opacity: 0, y: -8 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.6, ease: EASE }}
      className={cn(
        "fixed inset-x-0 top-0 z-50 border-b transition-[background-color,border-color,backdrop-filter] duration-300",
        scrolled
          ? "border-white/[0.06] bg-background/70 backdrop-blur-xl backdrop-saturate-150"
          : "border-transparent bg-transparent",
      )}
    >
      <nav className="mx-auto flex h-14 max-w-6xl items-center justify-between px-4 sm:px-6">
        <a href="#top" className="flex items-center gap-2 rounded-md text-[15px] font-semibold tracking-tight">
          <ParallelMark className="size-[22px]" />
          Parallex
        </a>
        <div className="flex items-center gap-1 sm:gap-2">
          <a
            href={REPO_URL}
            className="flex h-8 items-center gap-2 rounded-full px-3 text-[13px] text-foreground/75 transition-colors hover:bg-white/[0.06] hover:text-foreground"
          >
            <GitHubMark className="size-4" />
            <span className="max-sm:sr-only">GitHub</span>
          </a>
          <DownloadButton size="sm" />
        </div>
      </nav>
    </motion.header>
  )
}
