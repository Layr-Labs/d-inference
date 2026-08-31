"use client";

// "Earnings over time" — a small dependency-free SVG area chart over the
// per-day buckets derived client-side from the history rows.

import type { DayBucket } from "./aggregate";
import { formatDayLabel } from "./format";
import { microToUsd } from "@/lib/format/currency";

const W = 640;
const H = 220;
const PAD_X = 40;
const PAD_Y = 16;
const LABEL_H = 22;

export function EarningsChart({ days }: { days: DayBucket[] }) {
  return (
    <div className="rounded-xl bg-bg-secondary shadow-sm p-5">
      <h3 className="text-sm font-semibold text-text-primary mb-3">
        Earnings over time
      </h3>
      {days.length < 2 ? (
        <div className="flex items-center justify-center h-48 text-xs text-text-tertiary">
          Not enough history yet — the trend appears after a couple of days.
        </div>
      ) : (
        <ChartSvg days={days} />
      )}
    </div>
  );
}

function tickDecimalsFor(peakUsd: number): number {
  if (peakUsd < 1) return 2;
  if (peakUsd < 10) return 1;
  return 0;
}

function labelAnchor(i: number, len: number): "start" | "middle" | "end" {
  if (i === 0) return "start";
  if (i === len - 1) return "end";
  return "middle";
}

function ChartSvg({ days }: { days: DayBucket[] }) {
  const chartW = W - PAD_X * 2;
  const chartH = H - PAD_Y - LABEL_H;
  const peak = Math.max(...days.map((d) => d.micro), 1);
  // Tick precision that keeps small daily totals from all rounding to "$0".
  const tickDecimals = tickDecimalsFor(microToUsd(peak));

  const points = days.map((d, i) => ({
    x: PAD_X + (chartW * i) / (days.length - 1),
    y: PAD_Y + chartH * (1 - d.micro / peak),
    bucket: d,
  }));
  const line = points.map((p) => `${p.x},${p.y}`).join(" ");
  const area = `M${PAD_X},${PAD_Y + chartH} L${line.split(" ").join(" L")} L${
    PAD_X + chartW
  },${PAD_Y + chartH} Z`;

  // At most 6 x labels, always including first and last day.
  const step = Math.max(1, Math.ceil(days.length / 6));
  const labelIdx = new Set<number>([0, days.length - 1]);
  for (let i = step; i < days.length - 1; i += step) labelIdx.add(i);

  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      className="w-full h-auto"
      role="img"
      aria-label="Daily earnings trend"
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
              {formatDayLabel(p.bucket.day)}
            </text>
          ),
      )}
    </svg>
  );
}
