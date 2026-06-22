"use client";

import { Crown, Info } from "lucide-react";
import { fmtUSD } from "./calc";
import type { EarningsCalculator } from "./useEarningsCalculator";

export function ModelSelector({ calc }: { calc: EarningsCalculator }) {
  const {
    rankedModels,
    effectiveModelIds,
    bestModelId,
    catalogModels,
    selectedCatalogModels,
    selectedModelSizeGB,
    effectiveRAM,
    selectedModelIds,
    modelSelectorHint,
    toggleModel,
  } = calc;

  return (
    <div className="rounded-xl bg-bg-secondary p-6 mb-6">
      <div className="flex items-center gap-2 mb-2">
        <Crown size={14} className="text-text-tertiary" />
        <h3 className="text-sm font-medium text-text-primary">Model</h3>
      </div>
      <p className="text-xs text-text-tertiary mb-4">{modelSelectorHint}</p>

      {selectedCatalogModels.length > 0 && (
        <div className="mb-3 flex flex-wrap gap-2">
          <span className="px-2.5 py-1 rounded bg-bg-tertiary text-xs font-mono text-text-secondary">
            {selectedCatalogModels.length} model{selectedCatalogModels.length === 1 ? "" : "s"} selected
          </span>
          <span className="px-2.5 py-1 rounded bg-bg-tertiary text-xs font-mono text-text-tertiary">
            {selectedModelSizeGB} GB weights / {effectiveRAM} GB RAM
          </span>
        </div>
      )}

      <div className="rounded-lg border border-border-dim overflow-hidden">
        {rankedModels.map((m, i) => {
          const isSelected = effectiveModelIds.includes(m.modelId);
          const isBest = m.modelId === bestModelId;
          const catalogEntry = catalogModels.find((c) => c.id === m.modelId);
          const isUnprofitable = m.monthlyNet < 0;
          const canAdd =
            selectedModelIds.length === 0 ||
            isSelected ||
            selectedModelSizeGB + (catalogEntry?.modelSizeGB ?? 0) <= effectiveRAM;
          return (
            <div key={m.modelId} className={i > 0 ? "border-t border-border-dim" : ""}>
              <button
                onClick={() => toggleModel(m.modelId)}
                className={`w-full flex items-center gap-3 px-4 py-3 text-left transition-colors ${
                  isSelected
                    ? "bg-accent-brand/10 border-l-2 border-l-accent-brand"
                    : "hover:bg-bg-tertiary border-l-2 border-l-transparent"
                }`}
                title={
                  !canAdd
                    ? "Not enough memory to add this model; clicking will switch to it instead"
                    : undefined
                }
              >
                <div
                  className={`w-4 h-4 rounded border-2 flex items-center justify-center shrink-0 ${
                    isSelected ? "border-accent-brand" : "border-text-tertiary/40"
                  }`}
                >
                  {isSelected && <div className="w-2 h-2 rounded-sm bg-accent-brand" />}
                </div>

                <span
                  className={`text-sm font-medium flex-1 min-w-0 truncate ${
                    isUnprofitable
                      ? "text-text-tertiary line-through"
                      : isSelected
                      ? "text-text-primary"
                      : "text-text-secondary"
                  }`}
                >
                  {m.modelName}
                </span>

                <span
                  className={`text-sm font-mono tabular-nums whitespace-nowrap ${
                    m.monthlyNet >= 0 ? "text-accent-green" : "text-accent-red"
                  }`}
                >
                  {fmtUSD(m.monthlyNet)}/mo usage
                </span>

                {isBest && m.monthlyNet > 0 && (
                  <span className="px-2 py-0.5 rounded text-xs font-medium bg-accent-green/10 text-accent-green border border-accent-green/20 whitespace-nowrap">
                    Best model
                  </span>
                )}
              </button>
              {isSelected && catalogEntry?.demandNote && (
                <div className="px-4 pb-3 pl-11">
                  <div className="flex items-start gap-1.5 text-xs text-text-tertiary">
                    <Info size={11} className="shrink-0 mt-0.5" />
                    <span>
                      {catalogEntry.demandNote}
                      {isUnprofitable
                        ? " This model's usage revenue is below its electricity cost on your hardware — the base reward still applies."
                        : ""}
                    </span>
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {rankedModels.length === 0 && (
        <div className="text-center py-6 text-sm text-text-tertiary">
          {catalogModels.length === 0
            ? "No live priced models available yet"
            : `No models fit in ${effectiveRAM} GB RAM`}
        </div>
      )}
    </div>
  );
}
