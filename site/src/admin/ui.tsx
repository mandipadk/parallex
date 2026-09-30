import type { ReactNode } from "react"
import type { Verdict } from "../../worker/health"
import { number } from "./format"

const cx = (...names: (string | false | null | undefined)[]) => names.filter(Boolean).join(" ")

export function Card({ title, note, action, children, className, flush }: {
  title?: ReactNode
  note?: ReactNode
  action?: ReactNode
  children: ReactNode
  className?: string
  /** Content runs to the card's edges (tables). */
  flush?: boolean
}) {
  return (
    <section className={cx("min-w-0 rounded-2xl border bg-surface", className)}>
      {(title || action) && (
        <header className="flex items-start justify-between gap-4 px-5 pt-4">
          <div className="min-w-0">
            {title && <h2 className="text-[13.5px] font-semibold">{title}</h2>}
            {note && <p className="mt-0.5 text-[12.5px] text-muted">{note}</p>}
          </div>
          {action}
        </header>
      )}
      <div className={flush ? "pt-3" : "px-5 pt-3 pb-5"}>{children}</div>
    </section>
  )
}

export function Stat({ label, value, note, tone }: { label: string; value: ReactNode; note?: ReactNode; tone?: "brand" | "good" }) {
  return (
    <div className="min-w-0 rounded-2xl border bg-surface px-5 py-4">
      <div className="text-[12.5px] text-muted">{label}</div>
      <div className={cx("tabular mt-1 text-[30px] leading-tight font-semibold tracking-tight", tone === "brand" && "text-brand", tone === "good" && "text-good")}>
        {value}
      </div>
      {note && <div className="mt-1 text-[12px] text-faint">{note}</div>}
    </div>
  )
}

const VERDICTS: Record<Verdict, { label: string; className: string }> = {
  failing: { label: "Failing", className: "bg-brand-soft text-brand" },
  watch: { label: "Watch", className: "bg-caution-soft text-caution" },
  healthy: { label: "Healthy", className: "bg-good-soft text-good" },
  early: { label: "Too early to tell", className: "bg-fill text-muted" },
}

export function VerdictTag({ verdict }: { verdict: Verdict }) {
  const { label, className } = VERDICTS[verdict]
  return <span className={cx("inline-flex h-6 items-center rounded-full px-2.5 text-[12px] font-medium whitespace-nowrap", className)}>{label}</span>
}

export function Tag({ children, tone = "plain" }: { children: ReactNode; tone?: "plain" | "brand" | "good" | "caution" }) {
  const tones = { plain: "bg-fill text-muted", brand: "bg-brand-soft text-brand", good: "bg-good-soft text-good", caution: "bg-caution-soft text-caution" }
  return <span className={cx("inline-flex h-5 items-center rounded-full px-2 text-[11.5px] font-medium whitespace-nowrap", tones[tone])}>{children}</span>
}

/** Rows with a bar each, sized against the largest (or `total`). */
export function Bars({ items, total, empty = "Nothing yet.", format = (n: number) => number(n), limit = 10 }: {
  items: { name: string; count: number; hint?: string }[]
  total?: number
  empty?: string
  format?: (n: number) => string
  limit?: number
}) {
  if (!items.length) return <Empty>{empty}</Empty>
  const top = total ?? Math.max(...items.map((i) => i.count), 1)
  return (
    <div className="grid gap-2.5">
      {items.slice(0, limit).map((item) => (
        <div key={item.name} className="grid gap-1">
          <div className="flex items-baseline justify-between gap-3 text-[13px]">
            <span className="truncate">{item.name}{item.hint && <span className="ml-1.5 text-faint">{item.hint}</span>}</span>
            <span className="tabular shrink-0 text-muted">{format(item.count)}</span>
          </div>
          <div className="h-1.5 overflow-hidden rounded-full bg-fill">
            <div className="h-full rounded-full bg-brand" style={{ width: `${Math.max(2, Math.min(100, (item.count / top) * 100))}%` }} />
          </div>
        </div>
      ))}
    </div>
  )
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="py-2 text-[13px] text-faint">{children}</p>
}

/** A choice of a few, one selected. */
export function Segmented<T extends string | number>({ options, value, onChange, label }: {
  options: { value: T; label: string }[]
  value: T
  onChange: (value: T) => void
  label: string
}) {
  return (
    <div role="radiogroup" aria-label={label} className="inline-flex rounded-full border bg-surface p-0.5">
      {options.map((option) => (
        <button
          key={option.value}
          role="radio"
          aria-checked={option.value === value}
          onClick={() => onChange(option.value)}
          className={cx(
            "h-7 rounded-full px-3 text-[12.5px] font-medium transition-colors",
            option.value === value ? "bg-ink text-surface" : "text-muted hover:text-ink",
          )}
        >
          {option.label}
        </button>
      ))}
    </div>
  )
}

export function Button({ children, onClick, tone = "plain", disabled, title }: {
  children: ReactNode
  onClick?: () => void
  tone?: "plain" | "primary" | "danger" | "current"
  disabled?: boolean
  title?: string
}) {
  const tones = {
    plain: "border bg-surface hover:border-faint",
    primary: "border border-brand bg-brand text-white hover:brightness-110",
    danger: "border border-brand/40 text-brand hover:bg-brand-soft",
    current: "border border-ink bg-ink text-surface",
  }
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      className={cx("h-8 rounded-full px-3.5 text-[12.5px] font-medium whitespace-nowrap transition disabled:opacity-40", tones[tone])}
    >
      {children}
    </button>
  )
}

/** A plain table; the first column is left-aligned, numbers right. */
export function Table({ head, rows, empty = "Nothing yet." }: { head: ReactNode[]; rows: ReactNode[][]; empty?: string }) {
  if (!rows.length) return <div className="px-5 pb-5"><Empty>{empty}</Empty></div>
  return (
    <div className="overflow-x-auto">
      <table className="w-full min-w-[560px] border-collapse text-[13px]">
        <thead>
          <tr className="text-left text-[12px] text-muted">
            {head.map((h, i) => (
              <th key={i} className={cx("border-b px-5 py-2 font-medium", i > 0 && "text-right")}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, r) => (
            <tr key={r} className="border-b last:border-b-0 hover:bg-raised">
              {row.map((cell, i) => (
                <td key={i} className={cx("tabular px-5 py-2.5 align-top", i > 0 && "text-right")}>{cell}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export function Problem({ children }: { children: ReactNode }) {
  return <div className="rounded-2xl border border-brand/30 bg-brand-soft px-5 py-4 text-[13px] text-brand">{children}</div>
}

export function Loading() {
  return (
    <div className="grid gap-4" aria-busy="true" aria-label="Loading">
      <div className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {[0, 1, 2, 3].map((i) => <div key={i} className="h-[104px] animate-pulse rounded-2xl border bg-surface" />)}
      </div>
      <div className="h-[280px] animate-pulse rounded-2xl border bg-surface" />
    </div>
  )
}

export function PageHead({ title, note, actions }: { title: string; note?: ReactNode; actions?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-4">
      <div>
        <h1 className="text-[24px] font-semibold tracking-tight">{title}</h1>
        {note && <p className="mt-1 max-w-[62ch] text-[13px] text-muted">{note}</p>}
      </div>
      {actions}
    </div>
  )
}
