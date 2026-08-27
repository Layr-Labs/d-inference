export const CAPACITY_SHED_REASONS = [
  "machine_busy",
  "queue_timeout",
  "queue_full",
  "capacity_exhausted",
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
  supplyRejects1h: number;
  supplyRejects24h: number;
  served24h: number;
  actualTTFTP95Ms1h: number | null;
  actualTTFTP95Ms24h: number | null;
  rejectedTTFTP95Ms1h: number | null;
  rejectedTTFTP95Ms24h: number | null;
}

export interface SupplyPressureSummary {
  supplyRejects1h: number;
  supplyRejects24h: number;
  served24h: number;
  supplyRejectShare24h: number | null;
  pressuredModels1h: number;
}

export type DominantSupplySignalKind =
  | "capacity"
  | "latency"
  | "unavailable"
  | "hardware_mismatch"
  | "mixed"
  | "none";

export interface DominantSupplySignal {
  kind: DominantSupplySignalKind;
  label: string;
  window: "1h" | "24h" | null;
}

interface RankedSignal {
  kind: Exclude<DominantSupplySignalKind, "mixed" | "none">;
  count1h: number;
  count24h: number;
}

const LABELS: Record<Exclude<DominantSupplySignalKind, "mixed" | "none">, string> = {
  capacity: "Capacity rejects",
  latency: "TTFT / deadline rejects",
  unavailable: "No eligible provider",
  hardware_mismatch: "Needs larger RAM",
};

function rankedSignals(counts: SupplySignalCounts): RankedSignal[] {
  return [
    {
      kind: "capacity",
      count1h: counts.capacitySheds1h,
      count24h: counts.capacitySheds24h,
    },
    {
      kind: "latency",
      count1h: counts.latencySheds1h,
      count24h: counts.latencySheds24h,
    },
    {
      kind: "unavailable",
      count1h: counts.unavailableSheds1h,
      count24h: counts.unavailableSheds24h,
    },
    {
      kind: "hardware_mismatch",
      count1h: counts.hardwareMismatches1h,
      count24h: counts.hardwareMismatches24h,
    },
  ];
}

export function getDominantSupplySignal(
  counts: SupplySignalCounts,
): DominantSupplySignal {
  const signals = rankedSignals(counts);
  const window = signals.some((signal) => signal.count1h > 0) ? "1h" : "24h";
  const countKey = window === "1h" ? "count1h" : "count24h";
  const topCount = Math.max(...signals.map((signal) => signal[countKey]));

  if (topCount === 0) {
    return { kind: "none", label: "No tracked rejects", window: null };
  }
  const leaders = signals.filter((signal) => signal[countKey] === topCount);
  if (leaders.length > 1) {
    return { kind: "mixed", label: "Mixed signals", window };
  }
  const dominant = leaders[0];
  return {
    kind: dominant.kind,
    label: LABELS[dominant.kind],
    window,
  };
}

export function supplyRejectShare(rejected: number, served: number): number | null {
  const total = rejected + served;
  return total > 0 ? rejected / total : null;
}

export function summarizeSupplyPressure(
  models: SupplyPressureModel[],
): SupplyPressureSummary {
  const summary = models.reduce(
    (acc, model) => {
      acc.supplyRejects1h += model.supplyRejects1h;
      acc.supplyRejects24h += model.supplyRejects24h;
      acc.served24h += model.served24h;
      if (model.supplyRejects1h + model.hardwareMismatches1h > 0) {
        acc.pressuredModels1h += 1;
      }
      return acc;
    },
    {
      supplyRejects1h: 0,
      supplyRejects24h: 0,
      served24h: 0,
      pressuredModels1h: 0,
    },
  );

  return {
    ...summary,
    supplyRejectShare24h: supplyRejectShare(
      summary.supplyRejects24h,
      summary.served24h,
    ),
  };
}
