import { StrictMode, useEffect, useState, type ReactNode } from "react"
import { createRoot } from "react-dom/client"
import { Activity, AppWindow, Bug, HeartHandshake, Inbox, LayoutDashboard, LogOut, Megaphone, Moon, Rocket, Sun, TrendingUp } from "lucide-react"
import "./admin.css"
import { AppsPage } from "./pages/apps"
import { CommunityPage } from "./pages/community"
import { CrashesPage } from "./pages/crashes"
import { GrowthPage } from "./pages/growth"
import { InboxPage } from "./pages/inbox"
import { NoticesPage } from "./pages/notices"
import { OverviewPage } from "./pages/overview"
import { ReleasesPage } from "./pages/releases"
import { Segmented } from "./ui"

export type Tab = "overview" | "releases" | "crashes" | "apps" | "inbox" | "notices" | "growth" | "community"
export type PageProps = { days: number; go: (tab: Tab) => void }

/** A notice to draft, handed to the Notices page (from Apps or the Inbox). */
export type DraftSeed = { bundle: string; name: string; versions: string; message: string; source: string }

export function draftNotice(seed: DraftSeed) {
  // Handed over in the tab's own storage, not the address, so a link can't
  // fill in a draft.
  try {
    sessionStorage.setItem("mc-draft", JSON.stringify(seed))
  } catch {
    // Without storage the form starts empty.
  }
  location.hash = "/notices"
  dispatchEvent(new Event("mc-draft"))
  scrollTo({ top: 0 })
}

const TABS: { tab: Tab; label: string; icon: ReactNode; page: (props: PageProps) => ReactNode }[] = [
  { tab: "overview", label: "Overview", icon: <LayoutDashboard />, page: (p) => <OverviewPage {...p} /> },
  { tab: "releases", label: "Releases", icon: <Rocket />, page: (p) => <ReleasesPage {...p} /> },
  { tab: "crashes", label: "Crashes", icon: <Bug />, page: (p) => <CrashesPage {...p} /> },
  { tab: "apps", label: "Apps", icon: <AppWindow />, page: (p) => <AppsPage {...p} /> },
  { tab: "inbox", label: "Inbox", icon: <Inbox />, page: (p) => <InboxPage {...p} /> },
  { tab: "notices", label: "Notices", icon: <Megaphone />, page: (p) => <NoticesPage {...p} /> },
  { tab: "growth", label: "Growth", icon: <TrendingUp />, page: (p) => <GrowthPage {...p} /> },
  { tab: "community", label: "Community", icon: <HeartHandshake />, page: (p) => <CommunityPage {...p} /> },
]

const tabFromHash = (): Tab => {
  const name = location.hash.replace(/^#\/?/, "").split("?")[0]
  return TABS.some((t) => t.tab === name) ? (name as Tab) : "overview"
}

const stored = (key: string) => {
  try {
    return localStorage.getItem(key)
  } catch {
    return null
  }
}
const store = (key: string, value: string) => {
  try {
    localStorage.setItem(key, value)
  } catch {
    // A private window: remembered for this visit only.
  }
}

function Mark() {
  return (
    <svg width="26" height="26" viewBox="0 0 64 64" aria-hidden="true">
      <rect x="8" y="8" width="36" height="36" rx="10" fill="none" stroke="var(--faint)" strokeWidth="3" />
      <rect x="20" y="20" width="36" height="36" rx="10" fill="var(--brand)" />
    </svg>
  )
}

function MissionControl() {
  const [tab, setTab] = useState<Tab>(tabFromHash)
  const [days, setDays] = useState(() => Number(stored("mc-days")) || 30)
  const [dark, setDark] = useState(() => document.documentElement.classList.contains("dark"))

  useEffect(() => {
    const follow = () => setTab(tabFromHash())
    addEventListener("hashchange", follow)
    return () => removeEventListener("hashchange", follow)
  }, [])
  useEffect(() => {
    document.title = `${TABS.find((t) => t.tab === tab)?.label} · Mission Control`
  }, [tab])

  const go = (next: Tab) => {
    location.hash = `/${next}`
    scrollTo({ top: 0 })
  }
  const choose = (next: number) => {
    setDays(next)
    store("mc-days", String(next))
  }
  const flip = () => {
    const next = !dark
    setDark(next)
    document.documentElement.classList.toggle("dark", next)
    store("mc-theme", next ? "dark" : "light")
  }
  const signOut = async () => {
    await fetch("/admin/sign-out", { method: "POST", credentials: "same-origin" })
    location.reload()
  }
  const current = TABS.find((t) => t.tab === tab) ?? TABS[0]

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[232px_minmax(0,1fr)]">
      <aside className="sticky top-0 z-20 border-b bg-ground/90 backdrop-blur lg:h-dvh lg:border-r lg:border-b-0 lg:bg-transparent">
        <div className="flex items-center justify-between gap-3 px-4 py-3 lg:px-5 lg:pt-6 lg:pb-5">
          <div className="flex items-center gap-2.5">
            <Mark />
            <div className="leading-tight">
              <div className="text-[14px] font-semibold">Mission Control</div>
              <div className="text-[12px] text-muted">Parallex</div>
            </div>
          </div>
          <div className="flex items-center gap-1 lg:hidden">
            <IconButton label={dark ? "Light appearance" : "Dark appearance"} onClick={flip}>{dark ? <Sun /> : <Moon />}</IconButton>
          </div>
        </div>
        <nav aria-label="Sections" className="flex gap-1 overflow-x-auto px-3 pb-2 lg:grid lg:gap-0.5 lg:px-3 lg:pb-0">
          {TABS.map((t) => (
            <a
              key={t.tab}
              href={`#/${t.tab}`}
              aria-current={t.tab === tab ? "page" : undefined}
              className={`flex h-9 shrink-0 items-center gap-2.5 rounded-xl px-3 text-[13.5px] font-medium transition-colors [&_svg]:size-4 ${
                t.tab === tab ? "bg-surface text-ink shadow-sm ring-1 ring-rule" : "text-muted hover:bg-fill hover:text-ink"
              }`}
            >
              {t.icon}
              {t.label}
            </a>
          ))}
        </nav>
        <div className="hidden gap-2 px-5 pt-6 lg:grid">
          <a href="/admin/classic" className="flex items-center gap-2 text-[12.5px] text-muted hover:text-ink [&_svg]:size-3.5"><Activity />Classic view</a>
          <button onClick={flip} className="flex items-center gap-2 text-left text-[12.5px] text-muted hover:text-ink [&_svg]:size-3.5">
            {dark ? <Sun /> : <Moon />}{dark ? "Light appearance" : "Dark appearance"}
          </button>
          <button onClick={signOut} className="flex items-center gap-2 text-left text-[12.5px] text-muted hover:text-ink [&_svg]:size-3.5"><LogOut />Sign out everywhere</button>
        </div>
      </aside>
      <main className="mx-auto grid w-full max-w-[1240px] content-start gap-5 px-4 py-5 lg:px-8 lg:py-7">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <span className="text-[12.5px] text-muted">Counts are of Macs, over the window chosen here.</span>
          <Segmented
            label="Window"
            value={days}
            onChange={choose}
            options={[{ value: 7, label: "7 days" }, { value: 30, label: "30 days" }, { value: 90, label: "90 days" }]}
          />
        </div>
        {current.page({ days, go })}
        <footer className="pt-6 pb-2 text-center text-[12px] text-faint">
          Nothing here names a person or a Mac: install numbers are random and renewed every 180 days. <a className="underline decoration-rule underline-offset-2 hover:text-muted" href="/privacy">What's collected</a>
        </footer>
      </main>
    </div>
  )
}

function IconButton({ label, onClick, children }: { label: string; onClick: () => void; children: ReactNode }) {
  return (
    <button aria-label={label} title={label} onClick={onClick} className="grid size-8 place-items-center rounded-full text-muted hover:bg-fill hover:text-ink [&_svg]:size-4">
      {children}
    </button>
  )
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MissionControl />
  </StrictMode>,
)
