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

const MACBOOK_AIR = "MacBook Air";
const MACBOOK_PRO = "MacBook Pro";
const MACBOOK_NEO = "MacBook Neo";
const MAC_MINI = "Mac Mini";
const IMAC = "iMac";
const MAC_STUDIO = "Mac Studio";
const MAC_PRO = "Mac Pro";
const M4_MAX_14_CORE = "M4 Max (14-core CPU)";
const M4_MAX_16_CORE = "M4 Max (16-core CPU)";

export const MAC_CONFIGS: MacConfig[] = [
  { macType: MACBOOK_NEO, chip: "A18 Pro", ramOptions: [8], bandwidthGBs: 60, idleWatts: 8, inferWatts: 12 },
  { macType: MACBOOK_AIR, chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 8, inferWatts: 12 },
  { macType: MACBOOK_AIR, chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
  { macType: MACBOOK_AIR, chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
  { macType: MACBOOK_AIR, chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 8, inferWatts: 12 },
  { macType: MACBOOK_AIR, chip: "M5", ramOptions: [16, 24, 32], bandwidthGBs: 153, idleWatts: 8, inferWatts: 12 },
  { macType: MACBOOK_PRO, chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 10, inferWatts: 20 },
  { macType: MACBOOK_PRO, chip: "M1 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
  { macType: MACBOOK_PRO, chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
  { macType: MACBOOK_PRO, chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 10, inferWatts: 20 },
  { macType: MACBOOK_PRO, chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 12, inferWatts: 30 },
  { macType: MACBOOK_PRO, chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400, idleWatts: 15, inferWatts: 40 },
  { macType: MACBOOK_PRO, chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 10, inferWatts: 20 },
  { macType: MACBOOK_PRO, chip: "M3 Pro", ramOptions: [18, 36], bandwidthGBs: 150, idleWatts: 15, inferWatts: 35 },
  { macType: MACBOOK_PRO, chip: "M3 Max (14-core CPU)", ramOptions: [36, 96], bandwidthGBs: 300, idleWatts: 20, inferWatts: 45 },
  { macType: MACBOOK_PRO, chip: "M3 Max (16-core CPU)", ramOptions: [48, 64, 128], bandwidthGBs: 400, idleWatts: 20, inferWatts: 45 },
  { macType: MACBOOK_PRO, chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 10, inferWatts: 20 },
  { macType: MACBOOK_PRO, chip: "M4 Pro", ramOptions: [24, 48], bandwidthGBs: 273, idleWatts: 12, inferWatts: 30 },
  { macType: MACBOOK_PRO, chip: M4_MAX_14_CORE, ramOptions: [36], bandwidthGBs: 410, idleWatts: 20, inferWatts: 50 },
  { macType: MACBOOK_PRO, chip: M4_MAX_16_CORE, ramOptions: [48, 64, 128], bandwidthGBs: 546, idleWatts: 20, inferWatts: 50 },
  { macType: MACBOOK_PRO, chip: "M5", ramOptions: [16, 24, 32], bandwidthGBs: 153, idleWatts: 10, inferWatts: 20 },
  { macType: MACBOOK_PRO, chip: "M5 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 307, idleWatts: 12, inferWatts: 30 },
  { macType: MACBOOK_PRO, chip: "M5 Max (32-core GPU)", ramOptions: [36], bandwidthGBs: 460, idleWatts: 20, inferWatts: 50 },
  { macType: MACBOOK_PRO, chip: "M5 Max (40-core GPU)", ramOptions: [48, 64, 128], bandwidthGBs: 614, idleWatts: 20, inferWatts: 50 },
  { macType: MAC_MINI, chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 5, inferWatts: 10 },
  { macType: MAC_MINI, chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 5, inferWatts: 12 },
  { macType: MAC_MINI, chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 8, inferWatts: 25 },
  { macType: MAC_MINI, chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 5, inferWatts: 15 },
  { macType: MAC_MINI, chip: "M4 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 273, idleWatts: 8, inferWatts: 25 },
  { macType: IMAC, chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 15, inferWatts: 40 },
  { macType: IMAC, chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 15, inferWatts: 40 },
  { macType: IMAC, chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 15, inferWatts: 40 },
  { macType: MAC_STUDIO, chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: MAC_STUDIO, chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800, idleWatts: 30, inferWatts: 90 },
  { macType: MAC_STUDIO, chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: MAC_STUDIO, chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 35, inferWatts: 100 },
  { macType: MAC_STUDIO, chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819, idleWatts: 35, inferWatts: 110 },
  { macType: MAC_STUDIO, chip: M4_MAX_14_CORE, ramOptions: [36], bandwidthGBs: 410, idleWatts: 25, inferWatts: 65 },
  { macType: MAC_STUDIO, chip: M4_MAX_16_CORE, ramOptions: [48, 64, 128], bandwidthGBs: 546, idleWatts: 25, inferWatts: 65 },
  { macType: MAC_PRO, chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 40, inferWatts: 120 },
];

const CHIP_ORDER = [
  "A18 Pro",
  "M1", "M1 Pro", "M1 Max", "M1 Ultra",
  "M2", "M2 Pro", "M2 Max", "M2 Ultra",
  "M3", "M3 Pro", "M3 Max (14-core CPU)", "M3 Max (16-core CPU)", "M3 Ultra",
  "M4", "M4 Pro", M4_MAX_14_CORE, M4_MAX_16_CORE,
  "M5", "M5 Pro", "M5 Max (32-core GPU)", "M5 Max (40-core GPU)",
];

export interface HardwareOption extends MacConfig {
  id: string;
}

const MAC_TYPE_ORDER = [
  MACBOOK_NEO,
  MACBOOK_AIR,
  MACBOOK_PRO,
  MAC_MINI,
  IMAC,
  MAC_STUDIO,
  MAC_PRO,
];

export function buildHardwareOptions(configs: MacConfig[] = MAC_CONFIGS): HardwareOption[] {
  const options = configs.map((config) => ({
    ...config,
    id: `${config.macType}:${config.chip}`,
    ramOptions: [...config.ramOptions].sort((a, b) => a - b),
  }));
  options.sort((a, b) => {
    const chipDelta = CHIP_ORDER.indexOf(a.chip) - CHIP_ORDER.indexOf(b.chip);
    if (chipDelta !== 0) return chipDelta;
    return MAC_TYPE_ORDER.indexOf(a.macType) - MAC_TYPE_ORDER.indexOf(b.macType);
  });
  return options;
}

export const HARDWARE_OPTIONS = buildHardwareOptions();
export const DEFAULT_HARDWARE_ID = `${MACBOOK_PRO}:${M4_MAX_16_CORE}`;
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
  baseRewardMaximumUSD: number;
  monthlyWorkNetUSD: number;
  monthlyNetMaximumUSD: number;
  annualWorkNetUSD: number;
  annualNetMaximumUSD: number;
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

export function baseRewardMaximumUSD(
  policy: EarningsMarketBaseRewards,
  memoryGB: number,
): number {
  if (
    !policy.enabled ||
    !Number.isFinite(memoryGB) ||
    !Number.isFinite(policy.monthly_pool_micro_usd) ||
    !Number.isFinite(policy.reduction_k) ||
    !Number.isFinite(policy.account_cap_fraction) ||
    memoryGB < 0 ||
    policy.monthly_pool_micro_usd < 0 ||
    policy.reduction_k < 0 ||
    policy.account_cap_fraction < 0 ||
    policy.account_cap_fraction > 1
  ) {
    return 0;
  }
  let selected = 0;
  let selectedMinRAM = -1;
  for (const tier of policy.tiers) {
    if (memoryGB >= tier.min_ram_gb && tier.min_ram_gb > selectedMinRAM) {
      selected = tier.monthly_micro_usd / 1_000_000;
      selectedMinRAM = tier.min_ram_gb;
    }
  }
  const poolUSD = policy.monthly_pool_micro_usd / 1_000_000;
  const accountCap =
    policy.account_cap_fraction > 0
      ? poolUSD * policy.account_cap_fraction
      : poolUSD;
  // This is an upper bound, not an expected allocation. Actual five-minute
  // draws can be lower due to same-period work offsets, eligibility, competing
  // machines, or reward already consumed by this payout account.
  return Math.min(selected, poolUSD, accountCap);
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
  const baseRewardMaximum = baseRewardMaximumUSD(baseRewards, memoryGB);
  const monthlyWorkNetUSD = payout.candidate - electricityUSD;
  const monthlyNetMaximumUSD = monthlyWorkNetUSD + baseRewardMaximum;

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
    baseRewardMaximumUSD: baseRewardMaximum,
    monthlyWorkNetUSD,
    monthlyNetMaximumUSD,
    annualWorkNetUSD: monthlyWorkNetUSD * 12,
    annualNetMaximumUSD: monthlyNetMaximumUSD * 12,
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

export function fmtUSDRange(minimum: number, maximum: number, decimals = 2): string {
  const lower = fmtUSD(minimum, decimals);
  const upper = fmtUSD(maximum, decimals);
  return lower === upper ? lower : `${lower}–${upper}`;
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
