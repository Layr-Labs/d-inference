"use client";

import { Check, Layers, X } from "lucide-react";
import { fmtUSDRange, unavailableReasonLabel } from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

function formatSize(sizeGB: number): string {
  return sizeGB < 10 ? sizeGB.toFixed(1) : sizeGB.toFixed(0);
}

export function ModelSupportList({ calc }: { calc: EarningsCalculator }) {
  const { modelRows, bestModel, effectiveRAM, marketState } = calc;
  const unavailable = marketState === "unavailable" || modelRows.length === 0;
  const ready = marketState === "ready" && modelRows.length > 0;

  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Layers size={14} className="text-text-secondary" />
        <h3 className="text-sm font-medium text-text-primary">What your Mac can run</h3>
      </div>
      <p className="text-xs text-text-secondary mb-4">
        Active public models rank by modeled work net after electricity; the range adds zero to
        the policy-capped base-reward maximum.
      </p>

      {marketState === "loading" && (
        <div className="text-center py-6 text-sm text-text-secondary">
          Loading trailing market data…
        </div>
      )}
      {marketState !== "loading" && unavailable && (
        <div className="text-center py-6 text-sm text-text-secondary">
          Estimate unavailable
        </div>
      )}
      {ready && (
        <ul className="rounded-lg border border-border-dim overflow-hidden">
          {modelRows.map(({ model, fits, estimate }, index) => {
            const isBest = Boolean(estimate && model.id === bestModel?.id);
            return (
              <li
                key={model.id}
                className={`flex items-center gap-3 px-4 py-3 ${
                  index > 0 ? "border-t border-border-dim" : ""
                } ${fits ? "" : "opacity-60"}`}
              >
                {fits ? (
                  <Check size={16} className="text-accent-green shrink-0" aria-hidden />
                ) : (
                  <X size={16} className="text-text-secondary shrink-0" aria-hidden />
                )}

                <div className="flex-1 min-w-0">
                  <p className={`text-sm font-medium truncate ${fits ? "text-text-primary" : "text-text-secondary"}`}>
                    {model.display_name}
                  </p>
                  <p className="text-xs text-text-secondary">
                    {fits
                      ? `Runs in your ${effectiveRAM} GB (${formatSize(model.size_gb)} GB weights)`
                      : `Needs ${model.min_ram_gb} GB+ of unified memory`}
                  </p>
                </div>

                {fits && estimate && (
                  <span className="text-sm font-mono tabular-nums whitespace-nowrap text-text-secondary">
                    {fmtUSDRange(
                      estimate.monthlyWorkNetUSD,
                      estimate.monthlyNetMaximumUSD,
                    )}
                    /mo net
                  </span>
                )}
                {fits && !estimate && (
                  <span className="text-xs whitespace-nowrap text-text-secondary">
                    {unavailableReasonLabel(model.unavailable_reason)}
                  </span>
                )}

                {isBest && (
                  <span className="px-2 py-0.5 rounded text-xs font-medium bg-accent-green/10 text-accent-green border border-accent-green/20 whitespace-nowrap">
                    Best estimate
                  </span>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
