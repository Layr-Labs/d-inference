"use client";

import { Check, Layers, X } from "lucide-react";
import { fmtUSD } from "./calc";
import type { EarningsCalculator, ModelRow } from "./useEarningsCalculator";

function formatSize(sizeGB: number): string {
  return sizeGB < 10 ? sizeGB.toFixed(1) : sizeGB.toFixed(0);
}

function unfitDetail(
  reason: ModelRow["fitReason"],
  model: ModelRow["model"],
  ramGB: number,
): string {
  if (reason === "chip") return `Requires an M${model.minChipGeneration} or newer chip`;
  if (reason === "kv") {
    return `Not enough KV headroom for a typical request on ${ramGB} GB`;
  }
  return `Requires at least ${model.minRAMGB} GB of unified memory`;
}

export function ModelSupportList({ calc }: { calc: EarningsCalculator }) {
  const { modelRows, bestModel, effectiveRAM } = calc;

  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Layers size={14} className="text-text-secondary" />
        <h3 className="text-sm font-medium text-text-primary">Models your Mac can run</h3>
      </div>
      <p className="text-xs text-text-secondary mb-4">
        Models are ranked by estimated monthly earning at the selected duty cycle.
      </p>

      {modelRows.length === 0 && (
        <div className="text-center py-6 text-sm text-text-secondary">
          Estimate unavailable
        </div>
      )}
      {modelRows.length > 0 && (
        <ul className="rounded-lg border border-border-dim overflow-hidden">
          {modelRows.map(({ model, fits, fitReason, estimate }, index) => {
            const isBest = Boolean(estimate && model.id === bestModel?.id);
            return (
              <li
                key={model.id}
                className={`flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:gap-3 ${
                  index > 0 ? "border-t border-border-dim" : ""
                } ${fits ? "" : "opacity-60"}`}
              >
                <div className="flex min-w-0 flex-1 items-start gap-3">
                  {fits ? (
                    <Check size={16} className="mt-0.5 shrink-0 text-accent-green" aria-hidden />
                  ) : (
                    <X size={16} className="mt-0.5 shrink-0 text-text-secondary" aria-hidden />
                  )}
                  <div className="min-w-0 flex-1">
                    <p className={`text-sm font-medium break-words ${fits ? "text-text-primary" : "text-text-secondary"}`}>
                      {model.displayName}
                    </p>
                    <p className="text-xs break-words text-text-secondary">
                      {fits
                        ? `Fits in your ${effectiveRAM} GB (${formatSize(model.sizeGB)} GB of model weights)`
                        : unfitDetail(fitReason, model, effectiveRAM)}
                    </p>
                  </div>
                </div>

                <div className="flex flex-wrap items-center gap-2 pl-7 sm:shrink-0 sm:pl-0">
                  {fits && estimate && (
                    <span className="text-sm font-mono tabular-nums text-text-secondary">
                      {fmtUSD(estimate.monthlyRevenueUSD)}/mo
                    </span>
                  )}
                  {fits && !estimate && (
                    <span className="text-xs text-text-secondary">
                      Earning estimate unavailable
                    </span>
                  )}
                  {isBest && (
                    <span className="rounded border border-accent-green/20 bg-accent-green/10 px-2 py-0.5 text-xs font-medium text-accent-green">
                      Best current estimate
                    </span>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
