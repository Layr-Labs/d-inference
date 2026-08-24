import type {
  EarningsMarketBaseRewards,
  EarningsMarketModel,
  EarningsUnavailableReason,
} from "@/lib/api";

export interface HardwareProfile {
  bandwidthGBs: number;
  idleWatts: number;
  inferWatts: number;
}

export interface MacConfig extends HardwareProfile {
  macType: string;
  chip: string;
  ramOptions: number[];
}

export const MAC_CONFIGS: MacConfig[] = [
  { macType: "MacBook Air", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 8, inferWatts: 12 },
  { macType: "MacBook Air", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
  { macType: "MacBook Air", chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
  { macType: "MacBook Air", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 8, inferWatts: 12 },
  { macType: "MacBook Pro", chip: "M1 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
  { macType: "MacBook Pro", chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
  { macType: "MacBook Pro", chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 10, inferWatts: 20 },
  { macType: "MacBook Pro", chip: "M3 Pro", ramOptions: [18, 36], bandwidthGBs: 150, idleWatts: 15, inferWatts: 35 },
  { macType: "MacBook Pro", chip: "M3 Max", ramOptions: [36, 48, 64, 96, 128], bandwidthGBs: 400, idleWatts: 20, inferWatts: 45 },
  { macType: "MacBook Pro", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 10, inferWatts: 20 },
  { macType: "MacBook Pro", chip: "M4 Pro", ramOptions: [24, 48], bandwidthGBs: 273, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M4 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 546, idleWatts: 20, inferWatts: 50 },
  { macType: "MacBook Pro", chip: "M5", ramOptions: [16, 24, 32], bandwidthGBs: 153, idleWatts: 10, inferWatts: 20 },
  { macType: "MacBook Pro", chip: "M5 Pro", ramOptions: [24, 48], bandwidthGBs: 300, idleWatts: 12, inferWatts: 30 },
  { macType: "MacBook Pro", chip: "M5 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 600, idleWatts: 20, inferWatts: 50 },
  { macType: "Mac Mini", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 5, inferWatts: 10 },
  { macType: "Mac Mini", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 5, inferWatts: 12 },
  { macType: "Mac Mini", chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 8, inferWatts: 25 },
  { macType: "Mac Mini", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 5, inferWatts: 15 },
  { macType: "Mac Mini", chip: "M4 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 273, idleWatts: 8, inferWatts: 25 },
  { macType: "Mac Studio", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: "Mac Studio", chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800, idleWatts: 30, inferWatts: 90 },
  { macType: "Mac Studio", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: "Mac Studio", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 35, inferWatts: 100 },
  { macType: "Mac Studio", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819, idleWatts: 35, inferWatts: 110 },
  { macType: "Mac Studio", chip: "M4 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 546, idleWatts: 25, inferWatts: 65 },
  { macType: "Mac Studio", chip: "M5 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 600, idleWatts: 25, inferWatts: 65 },
  { macType: "Mac Pro", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 40, inferWatts: 120 },
  { macType: "Mac Pro", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819, idleWatts: 40, inferWatts: 120 },
];

export interface ChipOption extends HardwareProfile {
  chip: string;
  ramOptions: number[];
}

const CHIP_ORDER = [
  "M1", "M1 Pro", "M1 Max", "M1 Ultra",
  "M2", "M2 Pro", "M2 Max", "M2 Ultra",
  "M3", "M3 Pro", "M3 Max", "M3 Ultra",
  "M4", "M4 Pro", "M4 Max",
  "M5", "M5 Pro", "M5 Max",
];

export function buildChipOptions(configs: MacConfig[] = MAC_CONFIGS): ChipOption[] {
  const byChip = new Map<string, ChipOption>();
  for (const config of configs) {
    const existing = byChip.get(config.chip);
    if (!existing) {
      byChip.set(config.chip, {
        chip: config.chip,
        ramOptions: [...config.ramOptions],
        bandwidthGBs: config.bandwidthGBs,
        idleWatts: config.idleWatts,
        inferWatts: config.inferWatts,
      });
      continue;
    }
    for (const ram of config.ramOptions) {
      if (!existing.ramOptions.includes(ram)) existing.ramOptions.push(ram);
    }
  }
  const options = [...byChip.values()];
  for (const option of options) option.ramOptions.sort((a, b) => a - b);
  options.sort((a, b) => CHIP_ORDER.indexOf(a.chip) - CHIP_ORDER.indexOf(b.chip));
  return options;
}

export const CHIP_OPTIONS = buildChipOptions();
export const DEFAULT_ELEC_COST_PER_KWH = 0.15;
export const MONTH_HOURS = 30 * 24;

export interface ModelEarningsEstimate {
  model: EarningsMarketModel;
  candidateTPS: number;
  candidateShare: number;
  workPoolUSD: number;
  workPayoutUSD: number;
  existingCapacityPayoutUSD: number;
  allocatedTokens: number;
  activeHours: number;
  idleElectricityUSD: number;
  workloadElectricityUSD: number;
  electricityUSD: number;
  baseRewardPotentialUSD: number;
  monthlyNetUSD: number;
  annualNetUSD: number;
}

export function candidateCapacityTPS(
  model: EarningsMarketModel,
  candidateBandwidthGBs: number,
): number | null {
  if (
    !Number.isFinite(candidateBandwidthGBs) ||
    candidateBandwidthGBs <= 0 ||
    model.benchmark_tps <= 0 ||
    model.benchmark_memory_bandwidth_gbps <= 0
  ) {
    return null;
  }
  const candidate =
    (model.benchmark_tps / model.benchmark_memory_bandwidth_gbps) *
    candidateBandwidthGBs;
  return Number.isFinite(candidate) && candidate > 0 ? candidate : null;
}

export function conservedCandidatePayout(
  poolUSD: number,
  existingCapacityTPS: number,
  candidateTPS: number,
): { candidate: number; existing: number; share: number } | null {
  if (
    !Number.isFinite(poolUSD) ||
    !Number.isFinite(existingCapacityTPS) ||
    !Number.isFinite(candidateTPS) ||
    poolUSD < 0 ||
    existingCapacityTPS <= 0 ||
    candidateTPS <= 0
  ) {
    return null;
  }
  const denominator = existingCapacityTPS + candidateTPS;
  const share = candidateTPS / denominator;
  const candidate = poolUSD * share;
  return {
    candidate,
    // Treat the existing fleet as the exact residual so floating-point
    // rounding can never make the represented shares exceed the fixed pool.
    existing: poolUSD - candidate,
    share,
  };
}

export function baseRewardPotentialUSD(
  policy: EarningsMarketBaseRewards,
  memoryGB: number,
): number {
  if (!policy.enabled) return 0;
  let selected = 0;
  let selectedMinRAM = -1;
  for (const tier of policy.tiers) {
    if (memoryGB >= tier.min_ram_gb && tier.min_ram_gb > selectedMinRAM) {
      selected = tier.monthly_micro_usd / 1_000_000;
      selectedMinRAM = tier.min_ram_gb;
    }
  }
  return selected;
}

export function calculateModelEstimate(
  model: EarningsMarketModel,
  hardware: HardwareProfile,
  memoryGB: number,
  baseRewards: EarningsMarketBaseRewards,
  electricityCostPerKWh = DEFAULT_ELEC_COST_PER_KWH,
): ModelEarningsEstimate | null {
  if (
    memoryGB < model.min_ram_gb ||
    !model.estimate_available ||
    model.work_payout_micro_usd <= 0 ||
    model.paid_tokens <= 0 ||
    model.paid_jobs <= 0 ||
    model.aggregate_tps <= 0 ||
    model.provider_supply <= 0 ||
    !Number.isFinite(hardware.idleWatts) ||
    !Number.isFinite(hardware.inferWatts) ||
    !Number.isFinite(electricityCostPerKWh) ||
    hardware.idleWatts < 0 ||
    hardware.inferWatts < 0 ||
    electricityCostPerKWh < 0
  ) {
    return null;
  }
  const candidateTPS = candidateCapacityTPS(model, hardware.bandwidthGBs);
  if (candidateTPS === null) return null;

  const workPoolUSD = model.work_payout_micro_usd / 1_000_000;
  const payout = conservedCandidatePayout(workPoolUSD, model.aggregate_tps, candidateTPS);
  if (!payout) return null;

  // Treat every paid prompt and completion token as decode work. This
  // deliberately overstates active time relative to faster prompt prefill.
  const allocatedTokens = model.paid_tokens * payout.share;
  const activeHours = Math.min(MONTH_HOURS, allocatedTokens / candidateTPS / 3600);
  const idleElectricityUSD =
    (hardware.idleWatts / 1000) * MONTH_HOURS * electricityCostPerKWh;
  const workloadElectricityUSD =
    (Math.max(0, hardware.inferWatts - hardware.idleWatts) / 1000) *
    activeHours *
    electricityCostPerKWh;
  const electricityUSD = idleElectricityUSD + workloadElectricityUSD;
  const baseReward = baseRewardPotentialUSD(baseRewards, memoryGB);
  const monthlyNetUSD = payout.candidate + baseReward - electricityUSD;

  return {
    model,
    candidateTPS,
    candidateShare: payout.share,
    workPoolUSD,
    workPayoutUSD: payout.candidate,
    existingCapacityPayoutUSD: payout.existing,
    allocatedTokens,
    activeHours,
    idleElectricityUSD,
    workloadElectricityUSD,
    electricityUSD,
    baseRewardPotentialUSD: baseReward,
    monthlyNetUSD,
    annualNetUSD: monthlyNetUSD * 12,
  };
}

export function unavailableReasonLabel(
  reason: EarningsUnavailableReason | undefined,
): string {
  switch (reason) {
    case "settled_work_unavailable":
      return "Settled payout data unavailable";
    case "competing_capacity_unavailable":
      return "Competing capacity unavailable";
    case "throughput_benchmark_unavailable":
      return "Supply benchmark unavailable";
    default:
      return "Estimate unavailable";
  }
}

export function fmtUSD(value: number, decimals = 2): string {
  const absolute = Math.abs(value).toFixed(decimals);
  return value < 0 ? `-$${absolute}` : `$${absolute}`;
}

export function fmtUSDWhole(value: number): string {
  const absolute = Math.abs(value).toLocaleString(undefined, {
    maximumFractionDigits: 0,
  });
  return value < 0 ? `-$${absolute}` : `$${absolute}`;
}

export function fmtTokens(value: number): string {
  return Math.round(value).toLocaleString();
}
