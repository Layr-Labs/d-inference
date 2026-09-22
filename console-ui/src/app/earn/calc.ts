export interface HardwareProfile {
  bandwidthGBs: number;
}

export interface MacConfig extends HardwareProfile {
  macType: string;
  chip: string;
  ramOptions: number[];
}

const MACBOOK_PRO = "MacBook Pro";
const MAC_MINI = "Mac Mini";
const MAC_STUDIO = "Mac Studio";
const MAC_PRO = "Mac Pro";
const M4_MAX_14_CORE = "M4 Max (14-core CPU)";
const M4_MAX_16_CORE = "M4 Max (16-core CPU)";

export const MAC_CONFIGS: MacConfig[] = [
  { macType: MACBOOK_PRO, chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68 },
  { macType: MACBOOK_PRO, chip: "M1 Pro", ramOptions: [16, 32], bandwidthGBs: 200 },
  { macType: MACBOOK_PRO, chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400 },
  { macType: MACBOOK_PRO, chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100 },
  { macType: MACBOOK_PRO, chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200 },
  { macType: MACBOOK_PRO, chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400 },
  { macType: MACBOOK_PRO, chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100 },
  { macType: MACBOOK_PRO, chip: "M3 Pro", ramOptions: [18, 36], bandwidthGBs: 150 },
  { macType: MACBOOK_PRO, chip: "M3 Max (14-core CPU)", ramOptions: [36, 96], bandwidthGBs: 300 },
  { macType: MACBOOK_PRO, chip: "M3 Max (16-core CPU)", ramOptions: [48, 64, 128], bandwidthGBs: 400 },
  { macType: MACBOOK_PRO, chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120 },
  { macType: MACBOOK_PRO, chip: "M4 Pro", ramOptions: [24, 48], bandwidthGBs: 273 },
  { macType: MACBOOK_PRO, chip: M4_MAX_14_CORE, ramOptions: [36], bandwidthGBs: 410 },
  { macType: MACBOOK_PRO, chip: M4_MAX_16_CORE, ramOptions: [48, 64, 128], bandwidthGBs: 546 },
  { macType: MACBOOK_PRO, chip: "M5", ramOptions: [16, 24, 32], bandwidthGBs: 153 },
  { macType: MACBOOK_PRO, chip: "M5 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 307 },
  { macType: MACBOOK_PRO, chip: "M5 Max (32-core GPU)", ramOptions: [36], bandwidthGBs: 460 },
  { macType: MACBOOK_PRO, chip: "M5 Max (40-core GPU)", ramOptions: [48, 64, 128], bandwidthGBs: 614 },
  { macType: MAC_MINI, chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68 },
  { macType: MAC_MINI, chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100 },
  { macType: MAC_MINI, chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200 },
  { macType: MAC_MINI, chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120 },
  { macType: MAC_MINI, chip: "M4 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 273 },
  { macType: MAC_MINI, chip: "M5 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 307 },
  { macType: MAC_MINI, chip: "M6", ramOptions: [16, 24, 32], bandwidthGBs: 170 },
  { macType: MAC_STUDIO, chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400 },
  { macType: MAC_STUDIO, chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800 },
  { macType: MAC_STUDIO, chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400 },
  { macType: MAC_STUDIO, chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800 },
  { macType: MAC_STUDIO, chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819 },
  { macType: MAC_STUDIO, chip: "M5 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 1200 },
  { macType: MAC_STUDIO, chip: M4_MAX_14_CORE, ramOptions: [36], bandwidthGBs: 410 },
  { macType: MAC_STUDIO, chip: M4_MAX_16_CORE, ramOptions: [48, 64, 128], bandwidthGBs: 546 },
  { macType: MAC_STUDIO, chip: "M5 Max (32-core GPU)", ramOptions: [36], bandwidthGBs: 460 },
  { macType: MAC_STUDIO, chip: "M5 Max (40-core GPU)", ramOptions: [48, 64, 128], bandwidthGBs: 614 },
  { macType: MAC_PRO, chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800 },
];

const CHIP_ORDER = [
  "M1", "M1 Pro", "M1 Max", "M1 Ultra",
  "M2", "M2 Pro", "M2 Max", "M2 Ultra",
  "M3", "M3 Pro", "M3 Max (14-core CPU)", "M3 Max (16-core CPU)", "M3 Ultra",
  "M4", "M4 Pro", M4_MAX_14_CORE, M4_MAX_16_CORE,
  "M5", "M5 Pro", "M5 Max (32-core GPU)", "M5 Max (40-core GPU)", "M5 Ultra",
  "M6",
];

export interface HardwareOption extends MacConfig {
  id: string;
}

const MAC_TYPE_ORDER = [
  MACBOOK_PRO,
  MAC_MINI,
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
export const DEFAULT_DUTY_CYCLE_PERCENT = 5;
export const DECODE_BANDWIDTH_EFFICIENCY = 0.65;
export const MONTH_SECONDS = 30 * 24 * 60 * 60;
export const QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION = 700_000;

export interface FloorTier {
  minGB: number;
  label: string;
  floorUSD: number;
}

// Kept for the existing reference panel; the new calculator does not include
// base rewards in its earning estimate.
export const FLOOR_TIERS: FloorTier[] = [
  { minGB: 512, label: "512GB", floorUSD: 40 },
  { minGB: 192, label: "192GB", floorUSD: 30 },
  { minGB: 128, label: "128GB", floorUSD: 26 },
  { minGB: 96, label: "96GB", floorUSD: 22 },
  { minGB: 64, label: "64GB", floorUSD: 18 },
  { minGB: 48, label: "48GB", floorUSD: 16 },
  { minGB: 32, label: "32GB", floorUSD: 12 },
  { minGB: 24, label: "24GB", floorUSD: 10 },
  { minGB: 0, label: "Under 24GB", floorUSD: 0 },
];

export interface CalculatorModel {
  id: string;
  displayName: string;
  minRAMGB: number;
  sizeGB: number;
  activeParameterCount: number;
  bytesPerParameter: number;
  outputPriceMicroUSDPerMillion: number;
}

/** The three models Darkbloom supports today, pinned for a stable estimate. */
export const CALCULATOR_MODELS: CalculatorModel[] = [
  {
    id: "qwen3.6-35b-a3b-mxfp8",
    displayName: "Qwen3.6 35B A3B",
    minRAMGB: 48,
    sizeGB: 22,
    activeParameterCount: 3_000_000_000,
    bytesPerParameter: 22 / 35,
    outputPriceMicroUSDPerMillion: QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION,
  },
  {
    id: "gemma-4-26b-a4b-mxfp8",
    displayName: "Gemma 4 26B A4B",
    minRAMGB: 32,
    sizeGB: 17,
    activeParameterCount: 4_000_000_000,
    bytesPerParameter: 17 / 26,
    outputPriceMicroUSDPerMillion: 220_000,
  },
  {
    id: "gpt-oss-20b-mxfp4",
    displayName: "GPT-OSS 20B",
    minRAMGB: 24,
    sizeGB: 12,
    activeParameterCount: 3_600_000_000,
    bytesPerParameter: 12 / 20,
    outputPriceMicroUSDPerMillion: 69_000,
  },
];

export interface CapacityRevenueEstimate {
  model: CalculatorModel;
  activeWeightGBPerToken: number;
  decodeTokensPerSecond: number;
  dutyCyclePercent: number;
  activeSecondsPerMonth: number;
  outputTokensPerMonth: number;
  outputPriceUSDPerMillion: number;
  monthlyRevenueUSD: number;
  annualRevenueUSD: number;
}

export function calculateCapacityRevenue(
  model: CalculatorModel,
  hardware: HardwareProfile,
  memoryGB: number,
  dutyCyclePercent = DEFAULT_DUTY_CYCLE_PERCENT,
): CapacityRevenueEstimate | null {
  if (
    memoryGB < model.minRAMGB ||
    model.activeParameterCount <= 0 ||
    model.bytesPerParameter <= 0 ||
    model.outputPriceMicroUSDPerMillion <= 0 ||
    hardware.bandwidthGBs <= 0 ||
    dutyCyclePercent < 0 ||
    dutyCyclePercent > 100
  ) {
    return null;
  }

  const activeWeightGBPerToken =
    (model.activeParameterCount * model.bytesPerParameter) / 1_000_000_000;
  const decodeTokensPerSecond =
    (hardware.bandwidthGBs * DECODE_BANDWIDTH_EFFICIENCY) / activeWeightGBPerToken;
  const activeSecondsPerMonth = MONTH_SECONDS * (dutyCyclePercent / 100);
  const outputTokensPerMonth = decodeTokensPerSecond * activeSecondsPerMonth;
  const outputPriceUSDPerMillion = model.outputPriceMicroUSDPerMillion / 1_000_000;
  const monthlyRevenueUSD =
    (outputTokensPerMonth / 1_000_000) * outputPriceUSDPerMillion;

  if (!Number.isFinite(monthlyRevenueUSD)) return null;
  return {
    model,
    activeWeightGBPerToken,
    decodeTokensPerSecond,
    dutyCyclePercent,
    activeSecondsPerMonth,
    outputTokensPerMonth,
    outputPriceUSDPerMillion,
    monthlyRevenueUSD,
    annualRevenueUSD: monthlyRevenueUSD * 12,
  };
}

export function resolveHardwareRAM(ramOptions: number[], selectedRAM: number): number {
  return ramOptions.includes(selectedRAM)
    ? selectedRAM
    : ramOptions[ramOptions.length - 1] ?? 8;
}

export function fmtUSD(value: number, decimals = 2): string {
  const absolute = Math.abs(value).toLocaleString(undefined, {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
  return value < 0 ? `-$${absolute}` : `$${absolute}`;
}

export function fmtUSDWhole(value: number): string {
  const absolute = Math.abs(value).toLocaleString(undefined, {
    maximumFractionDigits: 0,
  });
  return value < 0 ? `-$${absolute}` : `$${absolute}`;
}
