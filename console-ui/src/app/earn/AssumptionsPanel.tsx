"use client";

import { ChevronDown } from "lucide-react";
import {
  ASSUMED_UTILIZATION,
  CONTINUOUS_BATCH_FACTOR,
  DEFAULT_ELEC_COST_PER_KWH,
  PROMPT_TO_COMPLETION_RATIO,
  SINGLE_STREAM_EFFICIENCY,
  fmtUSD,
  fmtUSDWhole,
} from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

/** One derivation step: what we compute, how, and the resulting value. */
function CalcStep({
  label,
  detail,
  value,
  emphasize = false,
}: {
  label: string;
  detail: string;
  value: string;
  emphasize?: boolean;
}) {
  return (
    <div className="flex items-center justify-between gap-4 px-4 py-3">
      <div className="min-w-0">
        <p className={`text-sm ${emphasize ? "font-semibold text-text-primary" : "font-medium text-text-primary"}`}>
          {label}
        </p>
        <p className="text-xs text-text-secondary mt-0.5">{detail}</p>
      </div>
      <p
        className={`text-sm font-mono tabular-nums whitespace-nowrap ${
          emphasize ? "font-semibold text-text-primary" : "text-text-secondary"
        }`}
      >
        {value}
      </p>
    </div>
  );
}

/**
 * Single collapsed home for everything that qualifies the hero number: the
 * usage/base-reward decomposition, the step-by-step derivation, and the
 * honesty caveats. Replaces the four separate explanation surfaces the old
 * page spread these across.
 */
export function AssumptionsPanel({ calc }: { calc: EarningsCalculator }) {
  const { result, chip, effectiveRAM } = calc;

  if (!result) return null;
  const best = result.selectedModels[0];
  const utilPct = Math.round(ASSUMED_UTILIZATION * 100);

  return (
    <details className="group rounded-xl bg-bg-secondary mb-6 open:pb-2">
      <summary className="flex items-center justify-between px-6 py-4 cursor-pointer list-none select-none">
        <span className="text-sm font-medium text-text-primary">
          How we estimate this
        </span>
        <ChevronDown
          size={16}
          className="text-text-secondary transition-transform group-open:rotate-180"
        />
      </summary>

      <div className="px-6 pb-4 space-y-5">
        {/* The honest framing, stated once */}
        <p className="text-sm text-text-secondary">
          The top of the range assumes healthy, sustained demand: your Mac serves requests{" "}
          <span className="text-text-primary font-medium">
            {Math.round(ASSUMED_UTILIZATION * 100)}% of the time
          </span>{" "}
          it is online, averaging {CONTINUOUS_BATCH_FACTOR} concurrent requests while active —
          not a saturated network (the engine can batch more at peak). Live demand fluctuates
          and can run below this, which is why we show a range: the base reward is what attested
          machines accrue for staying online regardless of traffic, and usage earnings grow with
          demand.
        </p>

        {/* Decomposition */}
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <div className="rounded-lg bg-bg-tertiary p-3 text-center">
            <p className="text-xs text-text-secondary mb-1">Usage (at {Math.round(ASSUMED_UTILIZATION * 100)}% util.)</p>
            <p className="text-lg font-mono text-text-primary">{fmtUSDWhole(result.monthlyUsageNet)}</p>
            <p className="text-xs text-text-secondary mt-0.5">revenue − electricity</p>
          </div>
          <div className="rounded-lg bg-accent-brand/5 border border-accent-brand/20 p-3 text-center">
            <p className="text-xs text-text-secondary mb-1">Base reward</p>
            <p className="text-lg font-mono text-accent-brand">+ {fmtUSDWhole(result.monthlyFloor)}</p>
            <p className="text-xs text-text-secondary mt-0.5">{effectiveRAM} GB tier, online ≥90%</p>
          </div>
          <div className="rounded-lg bg-accent-green/5 border border-accent-green/20 p-3 text-center">
            <p className="text-xs text-text-secondary mb-1">Top of range / mo</p>
            <p className="text-lg font-mono text-text-primary">{fmtUSDWhole(result.monthlyNet)}</p>
            <p className="text-xs text-text-secondary mt-0.5">usage + base reward</p>
          </div>
        </div>

        {/* Step-by-step derivation */}
        {best && (
          <div className="rounded-lg border border-border-dim divide-y divide-border-dim">
            <CalcStep
              label="Token speed"
              detail={`${chip.bandwidthGBs} GB/s memory bandwidth ÷ ${best.activeParamsGB} GB active weights × ${SINGLE_STREAM_EFFICIENCY} efficiency, serving ${CONTINUOUS_BATCH_FACTOR} requests at once ${utilPct}% of the time`}
              value={`${best.decodeTokPerSec.toFixed(0)} tok/s`}
            />
            <CalcStep
              label="Usage revenue"
              detail={`Those tokens billed at live per-token prices, plus the prompt tokens that come with them (${PROMPT_TO_COMPLETION_RATIO}:1), around the clock`}
              value={`${fmtUSDWhole(result.monthlyRevenue)} /mo`}
            />
            <CalcStep
              label="Electricity"
              detail={`${best.marginalWatts}W extra draw during inference at $${DEFAULT_ELEC_COST_PER_KWH.toFixed(2)}/kWh (US average) — only while actively serving`}
              value={`−${fmtUSD(result.monthlyElec)} /mo`}
            />
            <CalcStep
              label="Usage earnings"
              detail="Revenue minus electricity"
              value={`${fmtUSDWhole(result.monthlyUsageNet)} /mo`}
            />
            <CalcStep
              label="Base reward"
              detail={`${effectiveRAM} GB memory tier, paid for staying online ≥90% of each settlement period`}
              value={`+${fmtUSDWhole(result.monthlyFloor)} /mo`}
            />
            <CalcStep
              label="Top of range"
              detail="Usage earnings + base reward"
              value={`${fmtUSDWhole(result.monthlyNet)} /mo`}
              emphasize
            />
          </div>
        )}

        {/* Remaining caveats, merged */}
        <ul className="text-xs text-text-secondary space-y-1.5 list-disc pl-4">
          <li>
            Base rewards are paid to attested machines online ≥90% of each 5-minute settlement
            period, up to a fixed monthly budget — not a guarantee.
          </li>
          <li>
            Actual usage depends on network demand, model popularity, your reputation, and how
            many other providers serve the same model.
          </li>
        </ul>
      </div>
    </details>
  );
}
