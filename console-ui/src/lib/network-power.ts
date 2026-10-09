// Client-side network-power estimate.
//
// Mirrors the coordinator's registry.EstimateMachineWatts so the stats page can
// show a realistic "Network Power" figure derived from the provider hardware
// already present in /v1/stats — without waiting for the coordinator to expose a
// precomputed `active_power_watts` field. When that field IS present (newer
// coordinator), it is preferred verbatim.
//
// Figures are realistic Apple Silicon max sustained wall draw under compute
// (inference) load, grounded in Apple's power-consumption docs + independent
// measured max-load numbers — NOT the higher PSU-capacity rating.

const POWER_TABLE: Record<string, Record<string, number>> = {
  M1: { Base: 40, Pro: 60, Max: 115, Ultra: 215 },
  M2: { Base: 50, Pro: 75, Max: 140, Ultra: 280 },
  M3: { Base: 50, Pro: 75, Max: 150, Ultra: 290 },
  M4: { Base: 65, Pro: 100, Max: 170, Ultra: 300 },
  M5: { Base: 70, Pro: 105, Max: 180, Ultra: 310 },
};

function normalizeTier(tier?: string): "Base" | "Pro" | "Max" | "Ultra" {
  switch ((tier ?? "").trim().toLowerCase()) {
    case "ultra":
      return "Ultra";
    case "max":
      return "Max";
    case "pro":
      return "Pro";
    default:
      return "Base";
  }
}

// estimateMachineWatts returns the realistic max-load wall draw (watts) for one
// machine. Falls back to a GPU-core estimate for unknown/empty chip families.
export function estimateMachineWatts(
  chipFamily?: string,
  chipTier?: string,
  gpuCores?: number,
): number {
  const family = (chipFamily ?? "").trim().toUpperCase();
  const tier = POWER_TABLE[family];
  if (tier) return tier[normalizeTier(chipTier)];
  const cores = gpuCores ?? 0;
  if (cores <= 0) return 30;
  return Math.max(30, 30 + 3.5 * cores);
}

interface PowerProvider {
  chip_family?: string;
  chip_tier?: string;
  gpu_cores?: number;
}

interface PowerStats {
  active_power_watts?: number;
  providers?: PowerProvider[];
}

// activeNetworkPowerWatts returns the coordinator-provided active power if
// present, otherwise sums per-provider estimates over the online providers.
// Returns 0 when neither is available (caller hides the tile).
export function activeNetworkPowerWatts(stats: PowerStats): number {
  if (typeof stats.active_power_watts === "number" && stats.active_power_watts > 0) {
    return stats.active_power_watts;
  }
  return (stats.providers ?? []).reduce(
    (sum, p) => sum + estimateMachineWatts(p.chip_family, p.chip_tier, p.gpu_cores),
    0,
  );
}
