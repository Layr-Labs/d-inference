"use client";

import { Check, X, Layers } from "lucide-react";
import { fmtUSDWhole } from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

/**
 * Read-only "What your Mac can run" panel. The calculator always prices the
 * best-earning model automatically; this list answers the second question —
 * which models the selected hardware supports — without letting the user
 * accidentally lower their own estimate.
 */
export function ModelSupportList({ calc }: { calc: EarningsCalculator }) {
  const { modelRows, bestModel, effectiveRAM, catalogModels } = calc;

  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Layers size={14} className="text-text-secondary" />
        <h3 className="text-sm font-medium text-text-primary">What your Mac can run</h3>
      </div>
      <p className="text-xs text-text-secondary mb-4">
        Live network catalog. Your earnings estimate uses the best-earning model automatically.
      </p>

      {catalogModels.length === 0 ? (
        <div className="text-center py-6 text-sm text-text-secondary">
          Loading the live model catalog…
        </div>
      ) : (
        <ul className="rounded-lg border border-border-dim overflow-hidden">
          {modelRows.map(({ model, fits, earnings }, i) => {
            const isBest = fits && model.id === bestModel?.id;
            return (
              <li
                key={model.id}
                className={`flex items-center gap-3 px-4 py-3 ${
                  i > 0 ? "border-t border-border-dim" : ""
                } ${fits ? "" : "opacity-60"}`}
              >
                {fits ? (
                  <Check size={16} className="text-accent-green shrink-0" aria-hidden />
                ) : (
                  <X size={16} className="text-text-secondary shrink-0" aria-hidden />
                )}

                <div className="flex-1 min-w-0">
                  <p className={`text-sm font-medium truncate ${fits ? "text-text-primary" : "text-text-secondary"}`}>
                    {model.name}
                  </p>
                  <p className="text-xs text-text-secondary">
                    {fits
                      ? `Runs in your ${effectiveRAM} GB (${model.modelSizeGB} GB weights)`
                      : `Needs ${model.minRAMGB} GB+ of unified memory`}
                  </p>
                </div>

                {fits && earnings && (
                  <span className="text-sm font-mono tabular-nums whitespace-nowrap text-text-secondary">
                    {fmtUSDWhole(Math.max(0, earnings.monthlyNet))}/mo usage
                  </span>
                )}

                {isBest && (
                  <span className="px-2 py-0.5 rounded text-xs font-medium bg-accent-green/10 text-accent-green border border-accent-green/20 whitespace-nowrap">
                    Best earner
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
