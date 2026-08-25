"use client";

import { useEffect, useMemo, useState } from "react";
import { fetchModels } from "@/lib/api";
import {
  DEFAULT_DUTY_CYCLE_PERCENT,
  buildCalculatorModels,
  calculateCapacityRevenue,
  type CalculatorModel,
  type CapacityRevenueEstimate,
} from "./calc";
import { PROVIDER_HARDWARE_OPTIONS, isProviderReadyMemory } from "./providerReadiness";

export type CatalogState = "loading" | "ready" | "unavailable";

export interface ModelRow {
  model: CalculatorModel;
  fits: boolean;
  estimate: CapacityRevenueEstimate | null;
}

const MAC_TYPES = [...new Set(PROVIDER_HARDWARE_OPTIONS.map((option) => option.macType))];

export function useEarningsCalculator() {
  const [selectedMacType, setSelectedMacType] = useState("");
  const [selectedChip, setSelectedChip] = useState("");
  const [selectedRAM, setSelectedRAM] = useState<number | null>(null);
  const [dutyCyclePercent, setDutyCyclePercent] = useState(DEFAULT_DUTY_CYCLE_PERCENT);
  const [catalogState, setCatalogState] = useState<CatalogState>("loading");
  const [catalogModels, setCatalogModels] = useState<CalculatorModel[]>([]);

  useEffect(() => {
    let active = true;
    fetchModels()
      .then((models) => {
        if (!active) return undefined;
        const calculatorModels = buildCalculatorModels(models);
        setCatalogModels(calculatorModels);
        setCatalogState(calculatorModels.length > 0 ? "ready" : "unavailable");
        return undefined;
      })
      .catch(() => {
        if (!active) return undefined;
        setCatalogModels([]);
        setCatalogState("unavailable");
        return undefined;
      });
    return () => {
      active = false;
    };
  }, []);

  const availableChips = useMemo(
    () =>
      PROVIDER_HARDWARE_OPTIONS.filter(
        (option) => option.macType === selectedMacType,
      ).map((option) => option.chip),
    [selectedMacType],
  );
  const selectedHardware = useMemo(
    () =>
      PROVIDER_HARDWARE_OPTIONS.find(
        (option) => option.macType === selectedMacType && option.chip === selectedChip,
      ) ?? null,
    [selectedChip, selectedMacType],
  );
  const hardware = selectedHardware ?? PROVIDER_HARDWARE_OPTIONS[0];
  const availableRAM = selectedHardware?.ramOptions ?? [];
  const effectiveRAM =
    selectedRAM !== null && availableRAM.includes(selectedRAM) ? selectedRAM : 0;
  const isConfigured = selectedHardware !== null && effectiveRAM > 0;
  const isProductionReady = isConfigured && isProviderReadyMemory(effectiveRAM);

  const modelRows = useMemo<ModelRow[]>(() => {
    if (!isProductionReady || catalogState !== "ready") return [];
    const rows = catalogModels.map((model) => {
      const fits = model.minRAMGB <= effectiveRAM;
      return {
        model,
        fits,
        estimate: fits
          ? calculateCapacityRevenue(model, hardware, effectiveRAM, dutyCyclePercent)
          : null,
      };
    });
    rows.sort((a, b) => {
      if (a.fits !== b.fits) return a.fits ? -1 : 1;
      const earningDelta =
        (b.estimate?.monthlyRevenueUSD ?? 0) - (a.estimate?.monthlyRevenueUSD ?? 0);
      return earningDelta || a.model.minRAMGB - b.model.minRAMGB;
    });
    return rows;
  }, [catalogModels, catalogState, dutyCyclePercent, effectiveRAM, hardware, isProductionReady]);

  const bestRow = modelRows.find((row) => row.fits && row.estimate !== null) ?? null;

  return {
    isConfigured,
    isProductionReady,
    hardware,
    macTypes: MAC_TYPES,
    selectedMacType,
    selectMacType: (macType: string) => {
      setSelectedMacType(macType);
      setSelectedChip("");
      setSelectedRAM(null);
    },
    availableChips,
    selectedChip,
    selectChip: (chip: string) => {
      setSelectedChip(chip);
      setSelectedRAM(null);
    },
    availableRAM,
    selectedRAM,
    effectiveRAM,
    selectRAM: setSelectedRAM,
    dutyCyclePercent,
    selectDutyCyclePercent: setDutyCyclePercent,
    catalogState,
    modelRows,
    bestModel: bestRow?.model ?? null,
    result: bestRow?.estimate ?? null,
    hasFittingModel: modelRows.some((row) => row.fits),
  };
}

export type EarningsCalculator = ReturnType<typeof useEarningsCalculator>;
