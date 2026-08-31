import { formatMilliseconds, formatPercent } from "@/lib/format";
import {
  getDominantSupplySignal,
  supplyRejectShare,
  type SupplyPressureModel,
} from "@/lib/supply-pressure";

export function DominantSignal({ model }: { model: SupplyPressureModel }) {
  const signal = getDominantSupplySignal(model);
  const color =
    signal.window === "1h"
      ? "var(--red)"
      : signal.window === "24h"
        ? "var(--amber)"
        : "var(--green)";

  return (
    <div className="min-w-36">
      <span
        className="inline-flex rounded px-1.5 py-0.5 text-xs font-medium"
        style={{ background: "var(--bg-hover)", color }}
      >
        {signal.label}
      </span>
      <div className="mt-1 text-xs text-[var(--text-dim)]">
        {signal.window === "1h"
          ? "seen in the last hour"
          : signal.window === "24h"
            ? "seen in the last 24h"
            : "none in the last 24h"}
      </div>
    </div>
  );
}

export function SupplyRejectShareMeter({
  rejected,
  served,
}: {
  rejected: number;
  served: number;
}) {
  const ratio = supplyRejectShare(rejected, served);
  if (ratio === null) return <span className="text-[var(--text-dim)]">—</span>;

  const width = `${Math.min(100, Math.max(0, ratio * 100))}%`;
  const color = ratio >= 0.1 ? "var(--red)" : ratio > 0 ? "var(--amber)" : "var(--green)";

  return (
    <div className="min-w-24">
      <div className="text-right tabular-nums">{formatPercent(ratio)}</div>
      <div className="mt-1 h-1.5 overflow-hidden rounded bg-[var(--bg-hover)]">
        <div className="h-full rounded" style={{ width, background: color }} />
      </div>
    </div>
  );
}

export function TTFTValue({
  current,
  fallback,
}: {
  current: number | null;
  fallback: number | null;
}) {
  const value = current ?? fallback;
  if (value === null) return <span className="text-[var(--text-dim)]">—</span>;

  return (
    <span className="whitespace-nowrap">
      {formatMilliseconds(value)}
      <span className="ml-1 text-xs text-[var(--text-dim)]">
        {current === null ? "24h" : "1h"}
      </span>
    </span>
  );
}
