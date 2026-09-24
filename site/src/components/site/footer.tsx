import { KOFI_URL, REPO_URL, SPONSOR_URL } from "@/lib/site"
import { ParallelMark } from "./parallel-mark"

export function Footer() {
  const link = "transition-colors hover:text-foreground"
  return (
    <footer className="border-t border-white/[0.06]">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-4 py-8 text-[13px] text-subtle sm:flex-row sm:px-6">
        <div className="flex items-center gap-2">
          <ParallelMark className="size-4" />
          <span>© 2026 Parallex</span>
        </div>
        <div className="flex items-center gap-5">
          <a className={link} href={`${REPO_URL}/blob/main/LICENSE`}>MIT</a>
          <a className={link} href={REPO_URL}>GitHub</a>
          <a className={link} href={SPONSOR_URL}>Sponsor</a>
          <a className={link} href={KOFI_URL}>Ko-fi</a>
          <a className={link} href="/privacy">Privacy</a>
          <span>Made on a Mac</span>
        </div>
      </div>
    </footer>
  )
}
