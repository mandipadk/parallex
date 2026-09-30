import { useMemo, useRef, useState } from "react"
import { number, shortDay } from "./format"

export type Series = { key: string; label: string; color: string; values: number[]; area?: boolean }

const niceMax = (n: number) => {
  if (n <= 4) return 4
  const power = 10 ** Math.floor(Math.log10(n))
  const step = [1, 2, 2.5, 5, 10].find((s) => s * power >= n / 4) ?? 10
  return Math.ceil(n / (step * power)) * step * power
}

/**
 * Lines over days, with a crosshair that reads every series at a day.
 * Sized by its container; the first series may be filled below.
 */
export function LineChart({ days, series, height = 220 }: { days: string[]; series: Series[]; height?: number }) {
  const width = 720
  const pad = { top: 12, right: 8, bottom: 22, left: 36 }
  const [hover, setHover] = useState<number | null>(null)
  const svg = useRef<SVGSVGElement>(null)
  const max = niceMax(Math.max(1, ...series.flatMap((s) => s.values)))
  const x = (i: number) => pad.left + (days.length <= 1 ? 0 : (i / (days.length - 1)) * (width - pad.left - pad.right))
  const y = (v: number) => pad.top + (1 - v / max) * (height - pad.top - pad.bottom)
  const ticks = [0, max / 2, max]
  const labels = days.length > 1 ? [0, Math.floor((days.length - 1) / 2), days.length - 1] : [0]

  const move = (event: React.PointerEvent<SVGSVGElement>) => {
    const box = svg.current?.getBoundingClientRect()
    if (!box || days.length < 2) return
    const at = ((event.clientX - box.left) / box.width) * width
    const i = Math.round(((at - pad.left) / (width - pad.left - pad.right)) * (days.length - 1))
    setHover(Math.max(0, Math.min(days.length - 1, i)))
  }

  return (
    <div className="relative">
      <svg
        ref={svg}
        viewBox={`0 0 ${width} ${height}`}
        className="block h-auto w-full touch-none select-none"
        onPointerMove={move}
        onPointerLeave={() => setHover(null)}
        role="img"
        aria-label={series.map((s) => `${s.label}: ${number(s.values.at(-1) ?? 0)} on the last day`).join(", ")}
      >
        {ticks.map((t) => (
          <g key={t}>
            <line x1={pad.left} x2={width - pad.right} y1={y(t)} y2={y(t)} stroke="var(--rule)" />
            <text x={pad.left - 8} y={y(t) + 4} textAnchor="end" fontSize="11" fill="var(--faint)" className="tabular">{number(Math.round(t))}</text>
          </g>
        ))}
        {labels.map((i) => (
          <text key={i} x={x(i)} y={height - 4} textAnchor={i === 0 ? "start" : i === days.length - 1 ? "end" : "middle"} fontSize="11" fill="var(--faint)">
            {shortDay(days[i])}
          </text>
        ))}
        {series.map((s, index) => {
          const points = s.values.map((v, i) => `${x(i)},${y(v)}`).join(" ")
          return (
            <g key={s.key}>
              {index === 0 && s.area !== false && days.length > 1 && (
                <polygon points={`${x(0)},${y(0)} ${points} ${x(days.length - 1)},${y(0)}`} fill={s.color} fillOpacity="0.08" />
              )}
              <polyline points={points} fill="none" stroke={s.color} strokeWidth={index === 0 ? 2 : 1.5} strokeLinejoin="round" strokeLinecap="round" />
            </g>
          )
        })}
        {hover !== null && (
          <g>
            <line x1={x(hover)} x2={x(hover)} y1={pad.top} y2={height - pad.bottom} stroke="var(--faint)" strokeDasharray="3 3" />
            {series.map((s) => <circle key={s.key} cx={x(hover)} cy={y(s.values[hover] ?? 0)} r="3.5" fill="var(--surface)" stroke={s.color} strokeWidth="2" />)}
          </g>
        )}
      </svg>
      {hover !== null && (
        <div
          className="pointer-events-none absolute top-1 z-10 rounded-xl border bg-surface px-3 py-2 text-[12px] shadow-lg"
          style={{ left: `${(x(hover) / width) * 100}%`, transform: `translateX(${hover > days.length / 2 ? "calc(-100% - 12px)" : "12px"})` }}
        >
          <div className="mb-1 font-medium">{shortDay(days[hover])}</div>
          {series.map((s) => (
            <div key={s.key} className="flex items-center justify-between gap-4">
              <span className="flex items-center gap-2 text-muted"><i className="inline-block h-0.5 w-3 rounded" style={{ background: s.color }} />{s.label}</span>
              <span className="tabular font-medium">{number(s.values[hover] ?? 0)}</span>
            </div>
          ))}
        </div>
      )}
      <div className="mt-2 flex flex-wrap gap-4 text-[12px] text-muted">
        {series.map((s) => (
          <span key={s.key} className="flex items-center gap-2"><i className="inline-block h-0.5 w-3 rounded" style={{ background: s.color }} />{s.label}</span>
        ))}
      </div>
    </div>
  )
}

/** Each day's total split by version, newest version in the accent. */
export function StackedBars({ days, stacks, keys, height = 200 }: { days: string[]; stacks: Record<string, number>[]; keys: string[]; height?: number }) {
  const [hover, setHover] = useState<number | null>(null)
  const width = 720
  const pad = { top: 8, bottom: 22 }
  const totals = stacks.map((s) => keys.reduce((t, k) => t + (s[k] ?? 0), 0))
  const max = niceMax(Math.max(1, ...totals))
  const slot = width / Math.max(1, days.length)
  const shades = (i: number) => (i === 0 ? "var(--brand)" : `color-mix(in oklab, var(--ink) ${Math.max(12, 62 - i * 14)}%, transparent)`)
  return (
    <div className="relative">
      <svg viewBox={`0 0 ${width} ${height}`} className="block h-auto w-full" role="img" aria-label="Macs per version, each day" onPointerLeave={() => setHover(null)}>
        {stacks.map((stack, d) => {
          let top = height - pad.bottom
          return (
            <g key={days[d]} onPointerEnter={() => setHover(d)}>
              <rect x={d * slot} y={pad.top} width={slot} height={height - pad.top - pad.bottom} fill="transparent" />
              {keys.map((k, i) => {
                const h = ((stack[k] ?? 0) / max) * (height - pad.top - pad.bottom)
                top -= h
                return h > 0 ? <rect key={k} x={d * slot + slot * 0.18} y={top} width={slot * 0.64} height={h} rx={Math.min(2, slot * 0.2)} fill={shades(i)} opacity={hover === null || hover === d ? 1 : 0.55} /> : null
              })}
            </g>
          )
        })}
        {[0, days.length - 1].map((i) => (
          <text key={i} x={i === 0 ? 0 : width} y={height - 4} textAnchor={i === 0 ? "start" : "end"} fontSize="11" fill="var(--faint)">{days[i] ? shortDay(days[i]) : ""}</text>
        ))}
      </svg>
      {hover !== null && (
        <div className="pointer-events-none absolute top-0 z-10 rounded-xl border bg-surface px-3 py-2 text-[12px] shadow-lg"
          style={{ left: `${((hover + 0.5) / days.length) * 100}%`, transform: `translateX(${hover > days.length / 2 ? "calc(-100% - 10px)" : "10px"})` }}>
          <div className="mb-1 font-medium">{shortDay(days[hover])}</div>
          {keys.filter((k) => stacks[hover][k]).map((k, i) => (
            <div key={k} className="flex items-center justify-between gap-4">
              <span className="flex items-center gap-2 text-muted"><i className="inline-block size-2 rounded-sm" style={{ background: shades(keys.indexOf(k)) }} />{k}</span>
              <span className="tabular font-medium">{number(stacks[hover][k])}{i === 0 && totals[hover] ? <span className="ml-1 text-faint">{Math.round((stacks[hover][k] / totals[hover]) * 100)}%</span> : null}</span>
            </div>
          ))}
        </div>
      )}
      <div className="mt-2 flex flex-wrap gap-4 text-[12px] text-muted">
        {keys.slice(0, 5).map((k, i) => <span key={k} className="flex items-center gap-2"><i className="inline-block size-2 rounded-sm" style={{ background: shades(i) }} />{k}</span>)}
      </div>
    </div>
  )
}

/** A small line of daily counts. */
export function Spark({ values, width = 120, height = 28 }: { values: number[]; width?: number; height?: number }) {
  const points = useMemo(() => {
    const max = Math.max(1, ...values)
    return values.map((v, i) => `${(i / Math.max(1, values.length - 1)) * width},${height - 2 - (v / max) * (height - 4)}`).join(" ")
  }, [values, width, height])
  return (
    <svg viewBox={`0 0 ${width} ${height}`} width={width} height={height} aria-hidden="true" className="block">
      <polyline points={points} fill="none" stroke="var(--brand)" strokeWidth="1.5" strokeLinejoin="round" />
    </svg>
  )
}

/** A share, as a short meter. */
export function Meter({ value, tone = "brand" }: { value: number; tone?: "brand" | "good" }) {
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-full bg-fill">
      <div className={`h-full rounded-full ${tone === "good" ? "bg-good" : "bg-brand"}`} style={{ width: `${Math.max(0, Math.min(1, value)) * 100}%` }} />
    </div>
  )
}
