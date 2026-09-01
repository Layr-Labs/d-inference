"use client";

// "Earnings over time" — a small dependency-free SVG chart over the buckets
// derived client-side from the fetched history window (perBucketTotals picks
// hour or day granularity to fit the window's span). Two series share the x
// axis: earnings (area + line, left axis) and demand in jobs (dashed line,
// right axis). Each series is normalized to its own peak, so the two stay
// visually comparable no matter how far apart their magnitudes are. Model
// filtering happens upstream (ActivityFilterBar).

import { useState } from "react";
import type { DayBucket, Granularity } from "./aggregate";
import { formatBucketLabel } from "./format";
import { microToUsd } from "@/lib/format/currency";

const W = 640;
const H = 220;
const PAD_X = 40;
const PAD_Y = 16;
const LABEL_H = 22;

export function EarningsChart({
  days,
  granularity = "day",
  note,
}: {
  days: DayBucket[];
  /** Bucket size of `days` — drives axis and tooltip labels. */
  granularity?: Granularity;
  /** Coverage disclosure when the history window is truncated server-side. */
  note?: string | null;
}) {
  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
      <div className="mb-3">
        <h3 className="text-sm font-semibold text-text-primary">
          Earnings over time
        </h3>
        {note && (
          <p
            className="text-xs text-text-tertiary mt-0.5"
            data-testid="chart-coverage-note"
          >
            {note}
          </p>
        )}
      </div>
      {days.length < 2 ? (
        <div className="flex items-center justify-center h-48 text-xs text-text-tertiary">
          Not enough history yet — the trend appears once earnings span more
          than an hour.
        </div>
      ) : (
        <>
          <ChartSvg days={days} granularity={granularity} />
          <Legend />
        </>
      )}
    </div>
  );
}

function Legend() {
  return (
    <div className="flex items-center gap-4 mt-2 text-[11px] text-text-tertiary">
      <span className="flex items-center gap-1.5">
        <span
          className="inline-block w-3 h-0.5 rounded"
          style={{ backgroundColor: "var(--accent-brand)" }}
        />
        Earnings (USD)
      </span>
      <span className="flex items-center gap-1.5">
        <svg width="14" height="2" aria-hidden="true">
          <line
            x1="0"
            x2="14"
            y1="1"
            y2="1"
            stroke="var(--accent-amber)"
            strokeWidth="2"
            strokeDasharray="3 2"
          />
        </svg>
        Demand (jobs)
      </span>
    </div>
  );
}

/**
 * Tick decimals: enough that the midpoint tick keeps a nonzero digit, so
 * sub-cent peaks don't flatten the whole axis to "$0.00". Capped at 6, the
 * micro-USD floor.
 */
function tickDecimalsFor(peakUsd: number): number {
  if (peakUsd >= 10) return 0;
  if (peakUsd >= 1) return 1;
  const zeroAt = (d: number) => (peakUsd / 2).toFixed(d) === (0).toFixed(d);
  let decimals = 2;
  while (decimals < 6 && zeroAt(decimals)) decimals++;
  return decimals;
}

/** Compact jobs-axis tick: 843 -> "843", 48_860 -> "48.9k", 2_000_000 -> "2m". */
function formatJobsTick(n: number): string {
  const r = Math.round(n);
  if (r >= 1_000_000) return `${trimZero((r / 1_000_000).toFixed(1))}m`;
  if (r >= 1_000) return `${trimZero((r / 1_000).toFixed(1))}k`;
  return String(r);
}

function trimZero(s: string): string {
  return s.endsWith(".0") ? s.slice(0, -2) : s;
}

/** Tooltip dollars: cents precision normally, finer for sub-cent days. */
function formatHoverUsd(micro: number): string {
  const usd = microToUsd(micro);
  return `$${usd.toFixed(usd > 0 && usd < 0.01 ? 4 : 2)}`;
}

function labelAnchor(i: number, len: number): "start" | "middle" | "end" {
  if (i === 0) return "start";
  if (i === len - 1) return "end";
  return "middle";
}

function ChartSvg({
  days,
  granularity,
}: {
  days: DayBucket[];
  granularity: Granularity;
}) {
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);
  const chartW = W - PAD_X * 2;
  const chartH = H - PAD_Y - LABEL_H;
  const peak = Math.max(...days.map((d) => d.micro), 1);
  const peakJobs = Math.max(...days.map((d) => d.jobs), 1);
  // Tick precision that keeps small daily totals from all rounding to "$0".
  const tickDecimals = tickDecimalsFor(microToUsd(peak));

  const points = days.map((d, i) => ({
    x: PAD_X + (chartW * i) / (days.length - 1),
    y: PAD_Y + chartH * (1 - d.micro / peak),
    yJobs: PAD_Y + chartH * (1 - d.jobs / peakJobs),
    bucket: d,
  }));
  const baseline = PAD_Y + chartH;
  const line = points.map((p) => `${p.x},${p.y}`).join(" ");
  const demandLine = points.map((p) => `${p.x},${p.yJobs}`).join(" ");
  const area = `M${PAD_X},${baseline} ${points
    .map((p) => `L${p.x},${p.y}`)
    .join(" ")} L${PAD_X + chartW},${baseline} Z`;

  // At most 6 x labels, always including first and last day.
  const step = Math.max(1, Math.ceil(days.length / 6));
  const labelIdx = new Set<number>([0, days.length - 1]);
  for (let i = step; i < days.length - 1; i += step) labelIdx.add(i);

  // Map a mouse position (rendered px) to the nearest day index.
  const onMove = (e: React.MouseEvent<SVGSVGElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    if (rect.width === 0) return;
    const xView = ((e.clientX - rect.left) / rect.width) * W;
    const idx = Math.round(((xView - PAD_X) / chartW) * (days.length - 1));
    setHoverIdx(Math.max(0, Math.min(days.length - 1, idx)));
  };
  const hover = hoverIdx === null ? null : (points.at(hoverIdx) ?? null);

  return (
    <div className="relative">
      {hover && (
        <div
          data-testid="chart-tooltip"
          className="pointer-events-none absolute z-10 rounded-md border border-border-subtle bg-bg-primary px-2.5 py-1.5 shadow-md text-[11px] leading-4 whitespace-nowrap"
          style={{
            left: `${(hover.x / W) * 100}%`,
            top: 0,
            transform:
              hover.x > W / 2 ? "translateX(calc(-100% - 8px))" : "translateX(8px)",
          }}
        >
          <p className="font-medium text-text-primary">
            {formatBucketLabel(hover.bucket.day, granularity)}
          </p>
          <p style={{ color: "var(--accent-brand)" }}>
            {formatHoverUsd(hover.bucket.micro)} earned
          </p>
          <p style={{ color: "var(--accent-amber)" }}>
            {hover.bucket.jobs.toLocaleString("en-US")}{" "}
            {hover.bucket.jobs === 1 ? "job" : "jobs"}
          </p>
        </div>
      )}
      <svg
        viewBox={`0 0 ${W} ${H}`}
        className="w-full h-auto"
        role="img"
        aria-label="Earnings and demand trend"
        onMouseMove={onMove}
        onMouseLeave={() => setHoverIdx(null)}
      >
      <defs>
        <linearGradient id="earnings-area" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stopColor="var(--accent-brand)" stopOpacity="0.18" />
          <stop offset="100%" stopColor="var(--accent-brand)" stopOpacity="0.02" />
        </linearGradient>
      </defs>
      {[0, 0.5, 1].map((t) => (
        <g key={t}>
          <line
            x1={PAD_X}
            x2={W - PAD_X}
            y1={PAD_Y + chartH * t}
            y2={PAD_Y + chartH * t}
            stroke="var(--border-subtle)"
            strokeWidth="1"
          />
          <text
            x={PAD_X - 6}
            y={PAD_Y + chartH * t + 3}
            textAnchor="end"
            fontSize="10"
            fill="var(--text-tertiary)"
          >
            ${microToUsd(peak * (1 - t)).toFixed(tickDecimals)}
          </text>
          <text
            x={W - PAD_X + 6}
            y={PAD_Y + chartH * t + 3}
            textAnchor="start"
            fontSize="10"
            fill="var(--accent-amber)"
          >
            {formatJobsTick(peakJobs * (1 - t))}
          </text>
        </g>
      ))}
      <path d={area} fill="url(#earnings-area)" />
      <polyline
        points={line}
        fill="none"
        stroke="var(--accent-brand)"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <polyline
        data-testid="demand-line"
        points={demandLine}
        fill="none"
        stroke="var(--accent-amber)"
        strokeWidth="1.5"
        strokeDasharray="4 3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      {points.map(
        (p, i) =>
          labelIdx.has(i) && (
            <text
              key={p.bucket.day}
              x={p.x}
              y={H - 6}
              textAnchor={labelAnchor(i, days.length)}
              fontSize="10"
              fill="var(--text-tertiary)"
            >
              {formatBucketLabel(p.bucket.day, granularity)}
            </text>
          ),
      )}
      {hover && (
        <g data-testid="hover-marker" pointerEvents="none">
          <line
            x1={hover.x}
            x2={hover.x}
            y1={PAD_Y}
            y2={baseline}
            stroke="var(--border-default)"
            strokeWidth="1"
          />
          <circle cx={hover.x} cy={hover.y} r="3.5" fill="var(--accent-brand)" />
          <circle
            cx={hover.x}
            cy={hover.yJobs}
            r="3"
            fill="var(--accent-amber)"
          />
        </g>
      )}
      </svg>
    </div>
  );
}
