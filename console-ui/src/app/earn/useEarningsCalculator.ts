"use client";

import { useEffect, useMemo, useState } from "react";
import {
  fetchEarningsMarket,
  type EarningsMarketModel,
  type EarningsMarketResponse,
} from "@/lib/api";
import {
  DEFAULT_HARDWARE_ID,
  DEFAULT_ELEC_COST_PER_KWH,
  HARDWARE_OPTIONS,
  calculateModelEstimate,
  type ModelEarningsEstimate,
} from "./calc";

export type EarningsMarketState = "loading" | "ready" | "unavailable";

export interface ModelRow {
  model: EarningsMarketModel;
  fits: boolean;
  estimate: ModelEarningsEstimate | null;
}

export function useEarningsCalculator() {
  const [selectedHardwareID, setSelectedHardwareID] = useState(DEFAULT_HARDWARE_ID);
  const [selectedRAM, setSelectedRAM] = useState(48);
  const [marketState, setMarketState] = useState<EarningsMarketState>("loading");
  const [market, setMarket] = useState<EarningsMarketResponse | null>(null);

  useEffect(() => {
    let active = true;
    fetchEarningsMarket()
      .then((response) => {
        if (!active) return undefined;
        setMarket(response);
        setMarketState("ready");
        return undefined;
      })
      .catch(() => {
        if (!active) return undefined;
        setMarket(null);
        setMarketState("unavailable");
        return undefined;
      });
    return () => {
      active = false;
    };
  }, []);

  const hardware = useMemo(
    () =>
      HARDWARE_OPTIONS.find((option) => option.id === selectedHardwareID) ??
      HARDWARE_OPTIONS[0],
    [selectedHardwareID],
  );
  const availableRAM = hardware.ramOptions;
  const effectiveRAM = availableRAM.includes(selectedRAM)
    ? selectedRAM
    : availableRAM[availableRAM.length - 1] ?? 8;

  const modelRows = useMemo<ModelRow[]>(() => {
    if (marketState !== "ready" || !market) return [];
    const rows = market.models.map((model) => {
      const fits = model.min_ram_gb <= effectiveRAM;
      return {
        model,
        fits,
        estimate: fits
          ? calculateModelEstimate(
              model,
              hardware,
              effectiveRAM,
              market.base_rewards,
              DEFAULT_ELEC_COST_PER_KWH,
            )
          : null,
      };
    });
    rows.sort((a, b) => {
      if (a.fits !== b.fits) return a.fits ? -1 : 1;
      if (a.fits && b.fits) {
        if (Boolean(a.estimate) !== Boolean(b.estimate)) return a.estimate ? -1 : 1;
        const netDelta =
          (b.estimate?.monthlyNetUSD ?? 0) - (a.estimate?.monthlyNetUSD ?? 0);
        if (netDelta !== 0) return netDelta;
      }
      if (a.model.min_ram_gb !== b.model.min_ram_gb) {
        return a.model.min_ram_gb - b.model.min_ram_gb;
      }
      return a.model.id.localeCompare(b.model.id);
    });
    return rows;
  }, [market, marketState, hardware, effectiveRAM]);

  const bestRow = modelRows.find((row) => row.fits && row.estimate !== null) ?? null;

  return {
    hardwareOptions: HARDWARE_OPTIONS,
    hardware,
    selectedHardwareID: hardware.id,
    selectHardware: setSelectedHardwareID,
    availableRAM,
    effectiveRAM,
    selectRAM: setSelectedRAM,
    electricityCostPerKWh: DEFAULT_ELEC_COST_PER_KWH,
    marketState,
    market,
    modelRows,
    bestModel: bestRow?.model ?? null,
    result: bestRow?.estimate ?? null,
    hasFittingModel: modelRows.some((row) => row.fits),
  };
}

export type EarningsCalculator = ReturnType<typeof useEarningsCalculator>;
