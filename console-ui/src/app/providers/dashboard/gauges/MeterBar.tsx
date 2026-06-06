// Horizontal bars — the workhorse gauge for memory pressure, CPU, throughput,
// GPU memory, and token-budget headroom. Pure presentational; color is always
// paired with a mono number by the caller so it reads without color alone.

import { clampPct } from "../format";

export function MeterBar({
  value,
  colorClass,
  trackClass = "bg-bg-tertiary",
  height = "h-1.5",
  label,
}: {
  /** 0–100 (clamped). */
  value: number;
  /** Tailwind background class for the fill. */
  colorClass: string;
  trackClass?: string;
  height?: string;
  label?: string;
}) {
  const w = clampPct(value);
  return (
    <div
      role="meter"
      aria-valuenow={Math.round(w)}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-label={label}
      className={`w-full ${height} rounded-full ${trackClass} overflow-hidden`}
    >
      <div
        className={`h-full rounded-full ${colorClass} transition-[width] duration-500`}
        style={{ width: `${w}%` }}
      />
    </div>
  );
}

/**
 * Compute non-overlapping segment widths (percent of the track) so their sum
 * never exceeds 100%. Pure helper kept out of the component body so render
 * stays free of mutation.
 */
function stackedWidths(values: number[]): number[] {
  const widths: number[] = [];
  values.reduce((remaining, v) => {
    const w = Math.min(clampPct(v), remaining);
    widths.push(w);
    return Math.max(0, remaining - w);
  }, 100);
  return widths;
}

/**
 * Stacked bar — multiple fills laid left-to-right within one track. Used for
 * GPU memory (active + cache over total). Segment values are percentages of
 * the whole track and are clamped so they never overflow.
 */
export function StackedBar({
  segments,
  trackClass = "bg-bg-tertiary",
  height = "h-1.5",
  label,
}: {
  segments: { value: number; colorClass: string }[];
  trackClass?: string;
  height?: string;
  label?: string;
}) {
  const widths = stackedWidths(segments.map((s) => s.value));
  return (
    <div
      role="meter"
      aria-label={label}
      className={`w-full ${height} rounded-full ${trackClass} overflow-hidden flex`}
    >
      {segments.map((s, i) => (
        <div
          key={i}
          className={`h-full ${s.colorClass} transition-[width] duration-500 ${i === 0 ? "rounded-l-full" : ""}`}
          style={{ width: `${widths[i]}%` }}
        />
      ))}
    </div>
  );
}

/** Threshold color for "lower is better" utilization (memory pressure). */
export function pressureColor(fraction: number): string {
  if (fraction >= 0.9) return "bg-accent-red";
  if (fraction >= 0.6) return "bg-accent-amber";
  return "bg-accent-green";
}

/** Threshold color for CPU utilization. */
export function cpuColor(fraction: number): string {
  if (fraction >= 0.9) return "bg-accent-red";
  if (fraction >= 0.7) return "bg-accent-amber";
  return "bg-accent-brand";
}
