export const CAPACITY_SHED_REASONS = [
  "machine_busy",
  "queue_timeout",
  "queue_full",
] as const;

export const LATENCY_SHED_REASONS = [
  "ttft_too_slow",
  "first_chunk_timeout",
  "deadline_unreachable",
] as const;

export const AVAILABILITY_SHED_REASONS = ["no_provider"] as const;
export const HARDWARE_MISMATCH_REASONS = ["model_too_large"] as const;

export const SUPPLY_SHED_REASONS = [
  ...CAPACITY_SHED_REASONS,
  ...LATENCY_SHED_REASONS,
  ...AVAILABILITY_SHED_REASONS,
] as const;

export const TRACKED_SUPPLY_REASONS = [
  ...SUPPLY_SHED_REASONS,
  ...HARDWARE_MISMATCH_REASONS,
] as const;

export interface SupplySignalCounts {
  capacitySheds1h: number;
  capacitySheds24h: number;
  latencySheds1h: number;
  latencySheds24h: number;
  unavailableSheds1h: number;
  unavailableSheds24h: number;
  hardwareMismatches1h: number;
  hardwareMismatches24h: number;
}

export interface SupplyPressureModel extends SupplySignalCounts {
  model: string;
  displayName: string;
  minRamGB: number | null;
  unserved1h: number;
  unserved24h: number;
  served24h: number;
  actualTTFTP95Ms1h: number | null;
  actualTTFTP95Ms24h: number | null;
  rejectedTTFTP95Ms1h: number | null;
  rejectedTTFTP95Ms24h: number | null;
}

export interface SupplyPressureSummary {
  unserved1h: number;
  unserved24h: number;
  served24h: number;
  supplyLossRate24h: number | null;
  pressuredModels1h: number;
}

export type MachineRecommendationKind =
  | "add_machines"
  | "warm_or_faster"
  | "restore_supply"
  | "larger_machines"
  | "none";

export interface MachineRecommendation {
  kind: MachineRecommendationKind;
  label: string;
  window: "1h" | "24h" | null;
}

interface RankedSignal {
  kind: Exclude<MachineRecommendationKind, "none">;
  count1h: number;
  count24h: number;
}

const LABELS: Record<Exclude<MachineRecommendationKind, "none">, string> = {
  add_machines: "Add machines",
  warm_or_faster: "Warm / faster",
  restore_supply: "Restore / add supply",
  larger_machines: "Larger RAM",
};

function rankedSignals(counts: SupplySignalCounts): RankedSignal[] {
  return [
    {
      kind: "add_machines",
      count1h: counts.capacitySheds1h,
      count24h: counts.capacitySheds24h,
    },
    {
      kind: "warm_or_faster",
      count1h: counts.latencySheds1h,
      count24h: counts.latencySheds24h,
    },
    {
      kind: "restore_supply",
      count1h: counts.unavailableSheds1h,
      count24h: counts.unavailableSheds24h,
    },
    {
      kind: "larger_machines",
      count1h: counts.hardwareMismatches1h,
      count24h: counts.hardwareMismatches24h,
    },
  ];
}

export function getMachineRecommendation(
  counts: SupplySignalCounts,
): MachineRecommendation {
  const signals = rankedSignals(counts);
  const window = signals.some((signal) => signal.count1h > 0) ? "1h" : "24h";
  const countKey = window === "1h" ? "count1h" : "count24h";
  const dominant = signals.reduce((best, signal) =>
    signal[countKey] > best[countKey] ? signal : best,
  );

  if (dominant[countKey] === 0) {
    return { kind: "none", label: "No shortage", window: null };
  }
  return {
    kind: dominant.kind,
    label: LABELS[dominant.kind],
    window,
  };
}

export function supplyLossRate(unserved: number, served: number): number | null {
  const total = unserved + served;
  return total > 0 ? unserved / total : null;
}

export function summarizeSupplyPressure(
  models: SupplyPressureModel[],
): SupplyPressureSummary {
  const summary = models.reduce(
    (acc, model) => {
      acc.unserved1h += model.unserved1h;
      acc.unserved24h += model.unserved24h;
      acc.served24h += model.served24h;
      if (model.unserved1h + model.hardwareMismatches1h > 0) {
        acc.pressuredModels1h += 1;
      }
      return acc;
    },
    {
      unserved1h: 0,
      unserved24h: 0,
      served24h: 0,
      pressuredModels1h: 0,
    },
  );

  return {
    ...summary,
    supplyLossRate24h: supplyLossRate(summary.unserved24h, summary.served24h),
  };
}
