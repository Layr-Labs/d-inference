"use client";

import { useEffect, useMemo, useState } from "react";
import { fetchModels, fetchPricing, type Model } from "@/lib/api";
import {
  CHIP_OPTIONS,
  DEFAULT_ELEC_COST_PER_KWH,
  type CatalogModel,
  type ModelEarnings,
  buildCatalogModels,
  calculateModelEarnings,
  calculatePortfolioEarnings,
  tierFloorUSD,
} from "./calc";

// Always-on, at the demand assumptions in calc.ts (60% utilization, ~2.5
// concurrent requests while active). We deliberately don't expose
// utilization/hours — this is the realistic figure, not a saturated best case;
// the base-reward floor is added on top.
export const ALWAYS_ON_HOURS = 24;

/** One row of the read-only "What your Mac can run" list. */
export interface ModelRow {
  model: CatalogModel;
  fits: boolean;
  earnings: ModelEarnings | null; // null when the model doesn't fit
}

/**
 * Owns all earnings-calculator state + derivations. Two inputs (chip + memory);
 * electricity is baked in at the US-average $/kWh. The calculator always
 * prices the most profitable model that fits — there is no model selection.
 */
export function useEarningsCalculator() {
  const [selectedChip, setSelectedChip] = useState("M4 Max");
  const [selectedRAM, setSelectedRAM] = useState(48);
  const [catalogModels, setCatalogModels] = useState<CatalogModel[]>([]);

  const elecCostNum = DEFAULT_ELEC_COST_PER_KWH;

  useEffect(() => {
    Promise.all([
      fetchModels().catch(() => [] as Model[]),
      fetchPricing().catch(() => null),
    ]).then(([models, pricing]) => {
      setCatalogModels(buildCatalogModels(models, pricing));
    });
  }, []);

  const chip = useMemo(
    () => CHIP_OPTIONS.find((c) => c.chip === selectedChip) ?? CHIP_OPTIONS[0],
    [selectedChip],
  );

  const availableRAM = chip.ramOptions;
  const effectiveRAM = availableRAM.includes(selectedRAM)
    ? selectedRAM
    : availableRAM[availableRAM.length - 1] ?? 8;

  /**
   * Every catalog model, fitting models first (ranked by usage earnings),
   * then non-fitting models by how much memory they'd need.
   */
  const modelRows = useMemo<ModelRow[]>(() => {
    const rows = catalogModels.map((model) => {
      const fits = model.minRAMGB <= effectiveRAM;
      return {
        model,
        fits,
        earnings: fits
          ? calculateModelEarnings(model, chip, ALWAYS_ON_HOURS, elecCostNum)
          : null,
      };
    });
    rows.sort((a, b) => {
      if (a.fits !== b.fits) return a.fits ? -1 : 1;
      if (a.fits && b.fits) return (b.earnings?.monthlyNet ?? 0) - (a.earnings?.monthlyNet ?? 0);
      return a.model.minRAMGB - b.model.minRAMGB;
    });
    return rows;
  }, [catalogModels, chip, effectiveRAM, elecCostNum]);

  const bestModel = modelRows.find((r) => r.fits)?.model ?? null;

  const result = useMemo(() => {
    if (!bestModel) return null;
    return calculatePortfolioEarnings(
      [bestModel],
      chip,
      effectiveRAM,
      ALWAYS_ON_HOURS,
      elecCostNum,
    );
  }, [bestModel, chip, effectiveRAM, elecCostNum]);

  // Hero range: the base-reward floor is the only committed number; the
  // full-utilization estimate is the upside.
  const monthlyFloor = tierFloorUSD(effectiveRAM);
  const monthlyEstimate = result?.monthlyNet ?? monthlyFloor;

  return {
    chipOptions: CHIP_OPTIONS,
    chip,
    selectedChip: chip.chip,
    selectChip: setSelectedChip,
    availableRAM,
    effectiveRAM,
    selectRAM: setSelectedRAM,
    elecCostNum,
    catalogModels,
    modelRows,
    bestModel,
    result,
    monthlyFloor,
    monthlyEstimate,
  };
}

export type EarningsCalculator = ReturnType<typeof useEarningsCalculator>;
