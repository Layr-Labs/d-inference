"use client";

import { Check, Layers, X } from "lucide-react";
import { chipFitDetail, fmtUSD } from "./calc";
import type { EarningsCalculator, ModelRow } from "./useEarningsCalculator";

function formatSize(sizeGB: number): string {
  return sizeGB < 10 ? sizeGB.toFixed(1) : sizeGB.toFixed(0);
}

function unfitDetail(
  reason: ModelRow["fitReason"],
  model: ModelRow["model"],
  ramGB: number,
): string {
  if (reason === "chip") return chipFitDetail(model);
  if (reason === "kv") {
    return `Not enough KV headroom for a typical request on ${ramGB} GB`;
  }
  return `Requires at least ${model.minRAMGB} GB of unified memory`;
}

export function ModelSupportList({ calc }: { calc: EarningsCalculator }) {
  const { modelRows, bestModel, effectiveRAM } = calc;

  return (
    <div className="mb-6 rounded-xl bg-bg-secondary p-4 sm:p-6">
      <div className="mb-1 flex items-center gap-2">
        <Layers size={14} className="text-text-secondary" />
        <h3 className="text-sm font-medium text-text-primary">Models your Mac can run</h3>
      </div>
      <p className="mb-4 text-xs text-text-secondary">
        Models are ranked by estimated monthly earning at the selected duty cycle.
      </p>

      {modelRows.length === 0 && (
        <div className="py-6 text-center text-sm text-text-secondary">
          Estimate unavailable
        </div>
      )}
      {modelRows.length > 0 && (
        <ul
          aria-label="Supported models"
          className="overflow-hidden rounded-lg border border-border-dim"
        >
          {modelRows.map(({ model, fits, fitReason, estimate }, index) => {
            const isBest = Boolean(estimate && model.id === bestModel?.id);
            return (
              <li
                key={model.id}
                className={`grid grid-cols-[1rem_minmax(0,1fr)] gap-x-3 gap-y-1 px-3 py-3 sm:px-4 ${
                  index > 0 ? "border-t border-border-dim" : ""
                } ${fits ? "" : "opacity-60"}`}
              >
                {fits ? (
                  <Check size={16} className="mt-0.5 text-accent-green" aria-hidden />
                ) : (
                  <X size={16} className="mt-0.5 text-text-secondary" aria-hidden />
                )}
                <div className="min-w-0">
                  <p className={`text-sm font-medium ${fits ? "text-text-primary" : "text-text-secondary"}`}>
                    {model.displayName}
                  </p>
                  <p className="mt-0.5 text-xs text-text-secondary">
                    {fits
                      ? `Fits in your ${effectiveRAM} GB (${formatSize(model.sizeGB)} GB of model weights)`
                      : unfitDetail(fitReason, model, effectiveRAM)}
                  </p>
                  {(fits || isBest) && (
                    <div className="mt-1.5 flex flex-wrap items-center gap-2">
                      {fits && estimate && (
                        <span className="font-mono text-sm tabular-nums text-text-secondary">
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
