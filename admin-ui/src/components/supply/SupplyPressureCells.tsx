import { formatMilliseconds, formatPercent } from "@/lib/format";
import {
  getMachineRecommendation,
  supplyLossRate,
  type SupplyPressureModel,
} from "@/lib/supply-pressure";

export function MachineSignal({ model }: { model: SupplyPressureModel }) {
  const recommendation = getMachineRecommendation(model);
  const color =
    recommendation.window === "1h"
      ? "var(--red)"
      : recommendation.window === "24h"
        ? "var(--amber)"
        : "var(--green)";

  return (
    <div className="min-w-36">
      <span
        className="inline-flex rounded px-1.5 py-0.5 text-xs font-medium"
        style={{ background: "var(--bg-hover)", color }}
      >
        {recommendation.label}
      </span>
      <div className="mt-1 text-xs text-[var(--text-faint)]">
        {recommendation.window === "1h"
          ? "active in the last hour"
          : recommendation.window === "24h"
            ? "seen in the last 24h"
            : "no supply sheds in 24h"}
      </div>
    </div>
  );
}

export function SupplyLossMeter({
  unserved,
  served,
}: {
  unserved: number;
  served: number;
}) {
  const ratio = supplyLossRate(unserved, served);
  if (ratio === null) return <span className="text-[var(--text-faint)]">—</span>;

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
  if (value === null) return <span className="text-[var(--text-faint)]">—</span>;

  return (
    <span className="whitespace-nowrap">
      {formatMilliseconds(value)}
      <span className="ml-1 text-xs text-[var(--text-faint)]">
        {current === null ? "24h" : "1h"}
      </span>
    </span>
  );
}
