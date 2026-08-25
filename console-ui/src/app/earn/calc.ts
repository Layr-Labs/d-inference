import type { Model } from "@/lib/api";

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
  { macType: MAC_MINI, chip: "M6", ramOptions: [16, 24, 32], bandwidthGBs: 170 },
  { macType: MAC_STUDIO, chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400 },
  { macType: MAC_STUDIO, chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800 },
  { macType: MAC_STUDIO, chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400 },
  { macType: MAC_STUDIO, chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800 },
  { macType: MAC_STUDIO, chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819 },
  { macType: MAC_STUDIO, chip: "M5 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 1200 },
  { macType: MAC_STUDIO, chip: M4_MAX_14_CORE, ramOptions: [36], bandwidthGBs: 410 },
  { macType: MAC_STUDIO, chip: M4_MAX_16_CORE, ramOptions: [48, 64, 128], bandwidthGBs: 546 },
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

const QUANTIZATION_SUFFIXES = new Set([
  "qat",
  "q4",
  "q8",
  "int4",
  "int8",
  "4bit",
  "8bit",
  "mxfp4",
  "mxfp8",
  "fp4",
  "fp8",
]);

export interface CalculatorModel {
  id: string;
  displayName: string;
  minRAMGB: number;
  sizeGB: number;
  activeParameterCount: number;
  bytesPerParameter: number;
  outputPriceMicroUSDPerMillion: number;
}

function modelSizeGB(model: Model): number {
  if (model.size_gb && model.size_gb > 0) return model.size_gb;
  if (model.size_bytes && model.size_bytes > 0) return model.size_bytes / 1_000_000_000;
  return 0;
}

function modelTokens(model: Model): string[] {
  return `${model.id} ${model.display_name ?? ""} ${model.description ?? ""}`
    .toLowerCase()
    .split(/[^a-z0-9.]+/)
    .filter(Boolean);
}

function billionsToken(token: string): number {
  if (!token.endsWith("b")) return 0;
  const value = Number(token.slice(0, -1));
  return Number.isFinite(value) && value > 0 ? value : 0;
}

function parameterCountBillions(tokens: string[]): number {
  return tokens.map(billionsToken).find((value) => value > 0) ?? 0;
}

function activeParameterCount(tokens: string[], totalBillions: number): number {
  const activeToken = tokens.find((token) => token.startsWith("a") && token.endsWith("b"));
  const activeIndex = tokens.indexOf("active");
  let activeBillions = 0;
  if (activeToken) activeBillions = billionsToken(activeToken.slice(1));
  else if (activeIndex > 0) activeBillions = billionsToken(tokens[activeIndex - 1]);
  return (activeBillions || totalBillions) * 1_000_000_000;
}

function outputPrice(model: Model): number {
  if (model.id.toLowerCase().includes("qwen3.6-35b-a3b")) {
    return QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION;
  }
  const perTokenUSD = Number(model.pricing?.completion);
  return Number.isFinite(perTokenUSD) && perTokenUSD > 0
    ? Math.round(perTokenUSD * 1_000_000_000_000)
    : 0;
}

export function buildCalculatorModels(models: Model[]): CalculatorModel[] {
  const seen = new Set<string>();
  const result: CalculatorModel[] = [];

  for (const model of models) {
    const sizeGB = modelSizeGB(model);
    const tokens = modelTokens(model);
    const totalBillions = parameterCountBillions(tokens);
    const activeCount = activeParameterCount(tokens, totalBillions);
    const quantization = tokens.at(-1);
    const key = QUANTIZATION_SUFFIXES.has(quantization ?? "")
      ? model.id.slice(0, -(quantization!.length + 1))
      : model.id;
    if (seen.has(key) || sizeGB <= 0 || totalBillions <= 0 || activeCount <= 0) continue;
    seen.add(key);
    result.push({
      id: model.id,
      displayName: model.display_name || model.name || model.id,
      minRAMGB: model.min_ram_gb || Math.ceil(sizeGB * 1.35),
      sizeGB,
      activeParameterCount: activeCount,
      bytesPerParameter: sizeGB / totalBillions,
      outputPriceMicroUSDPerMillion: outputPrice(model),
    });
  }
  return result;
}

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
