"use client";

import { useEffect, useMemo, useState } from "react";
import { fetchModels, fetchPricing, type Model } from "@/lib/api";
import {
  MAC_CONFIGS,
  type CatalogModel,
  buildCatalogModels,
  calculateModelEarnings,
  calculatePortfolioEarnings,
  getComparisons,
} from "./calc";

// 80% utilization + always-on, with continuous batching at a quality-preserving
// 4x. We deliberately don't expose utilization/hours — this is the realistic
// "busy machine" figure; the base-reward floor is added on top.
export const ALWAYS_ON_HOURS = 24;

/**
 * Owns all earnings-calculator state + derivations (the orchestration that was
 * tangled into the 780-line page). The page and section components are now pure
 * presentation over this hook (proposal F7).
 */
export function useEarningsCalculator() {
  // Default: MacBook Pro -> M4 Max -> 48GB
  const [selectedMacType, setSelectedMacType] = useState("MacBook Pro");
  const [selectedChip, setSelectedChip] = useState("M4 Max");
  const [selectedRAM, setSelectedRAM] = useState(48);
  const [elecCost, setElecCost] = useState("0.15");
  const [selectedModelIds, setSelectedModelIds] = useState<string[]>([]);
  const [catalogModels, setCatalogModels] = useState<CatalogModel[]>([]);

  const elecCostNum = parseFloat(elecCost) || 0;

  useEffect(() => {
    Promise.all([
      fetchModels().catch(() => [] as Model[]),
      fetchPricing().catch(() => null),
    ]).then(([models, pricing]) => {
      setCatalogModels(buildCatalogModels(models, pricing));
    });
  }, []);

  const availableChips = useMemo(() => {
    const chips: string[] = [];
    for (const c of MAC_CONFIGS) {
      if (c.macType === selectedMacType && !chips.includes(c.chip)) {
        chips.push(c.chip);
      }
    }
    return chips;
  }, [selectedMacType]);

  const effectiveChip = availableChips.includes(selectedChip)
    ? selectedChip
    : availableChips[availableChips.length - 1];

  const selectedConfig = useMemo(
    () => MAC_CONFIGS.find((c) => c.macType === selectedMacType && c.chip === effectiveChip),
    [selectedMacType, effectiveChip],
  );

  const availableRAM = selectedConfig?.ramOptions ?? [];

  const effectiveRAM = availableRAM.includes(selectedRAM)
    ? selectedRAM
    : availableRAM[availableRAM.length - 1] ?? 8;

  const rankedModels = useMemo(() => {
    if (!selectedConfig) return [];
    const eligible = catalogModels.filter((m) => m.minRAMGB <= effectiveRAM);
    const results = eligible.map((m) =>
      calculateModelEarnings(m, selectedConfig, ALWAYS_ON_HOURS, elecCostNum),
    );
    results.sort((a, b) => b.monthlyNet - a.monthlyNet);
    return results;
  }, [selectedConfig, effectiveRAM, elecCostNum, catalogModels]);

  const bestModelId = rankedModels.length > 0 ? rankedModels[0].modelId : null;

  const eligibleModelIds = useMemo(
    () => new Set(rankedModels.map((m) => m.modelId)),
    [rankedModels],
  );

  const effectiveModelIds = useMemo(() => {
    const validSelected = selectedModelIds.filter((id) => eligibleModelIds.has(id));
    return validSelected.length > 0 ? validSelected : bestModelId ? [bestModelId] : [];
  }, [bestModelId, eligibleModelIds, selectedModelIds]);

  const selectedCatalogModels = useMemo(
    () =>
      effectiveModelIds
        .map((id) => catalogModels.find((m) => m.id === id))
        .filter((m): m is CatalogModel => Boolean(m)),
    [effectiveModelIds, catalogModels],
  );

  const selectedModelSizeGB = selectedCatalogModels.reduce(
    (sum, model) => sum + model.modelSizeGB,
    0,
  );

  const result = useMemo(() => {
    if (!selectedConfig || selectedCatalogModels.length === 0) return null;
    return calculatePortfolioEarnings(
      selectedCatalogModels,
      selectedConfig,
      effectiveRAM,
      ALWAYS_ON_HOURS,
      elecCostNum,
    );
  }, [selectedConfig, selectedCatalogModels, effectiveRAM, elecCostNum]);

  const comparisons = useMemo(
    () => (result ? getComparisons(result.monthlyNet) : []),
    [result],
  );

  // Hardware changes reset the model choice.
  const selectMacType = (macType: string) => {
    setSelectedMacType(macType);
    setSelectedModelIds([]);
  };
  const selectChip = (chip: string) => {
    setSelectedChip(chip);
    setSelectedModelIds([]);
  };
  const selectRAM = (ram: number) => {
    setSelectedRAM(ram);
    setSelectedModelIds([]);
  };

  const toggleModel = (modelId: string) => {
    const model = catalogModels.find((m) => m.id === modelId);
    if (!model) return;
    setSelectedModelIds((current) => {
      const validCurrent = current.filter((id) => eligibleModelIds.has(id));
      if (validCurrent.length === 0) return [modelId];
      const base = validCurrent;
      if (base.includes(modelId)) {
        const next = base.filter((id) => id !== modelId);
        return next.length > 0 ? next : base;
      }
      const currentSize = base.reduce((sum, id) => {
        const selected = catalogModels.find((m) => m.id === id);
        return sum + (selected?.modelSizeGB ?? 0);
      }, 0);
      if (currentSize + model.modelSizeGB > effectiveRAM) return [modelId];
      return [...base, modelId];
    });
  };

  let modelSelectorHint = "Auto-selected: most profitable model. Select more models if they fit in memory.";
  if (catalogModels.length === 0) {
    modelSelectorHint = "Loading live model catalog, or no priced models are currently available.";
  } else if (rankedModels.length === 0) {
    modelSelectorHint = "No compatible catalog model for this memory configuration";
  } else if (selectedModelIds.length > 0) {
    modelSelectorHint = "Selected models share active inference hours, so usage earnings are not double-counted.";
  }

  return {
    selectedMacType,
    effectiveChip,
    effectiveRAM,
    availableChips,
    availableRAM,
    selectedConfig,
    elecCost,
    elecCostNum,
    setElecCost,
    catalogModels,
    rankedModels,
    bestModelId,
    effectiveModelIds,
    selectedModelIds,
    selectedCatalogModels,
    selectedModelSizeGB,
    result,
    comparisons,
    modelSelectorHint,
    selectMacType,
    selectChip,
    selectRAM,
    toggleModel,
  };
}

export type EarningsCalculator = ReturnType<typeof useEarningsCalculator>;
