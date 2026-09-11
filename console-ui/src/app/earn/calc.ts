export interface HardwareProfile {
  bandwidthGBs: number;
  chip?: string;
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
export const DEFAULT_DUTY_CYCLE_PERCENT = 25;
export const DECODE_BANDWIDTH_EFFICIENCY = 0.65;
export const GEMMA_DECODE_BANDWIDTH_EFFICIENCY = 0.47;
export const PREFILL_TO_DECODE_RATIO = 12;
export const ENGINE_MAX_CONCURRENT = 4;
export const TYPICAL_PROMPT_TOKENS = 3200;
export const TYPICAL_COMPLETION_TOKENS = 400;
export const MONTH_SECONDS = 30 * 24 * 60 * 60;
export const QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION = 700_000;
export const SERVABILITY_CAP_FRACTION = 0.9;
export const ACTIVATION_RESERVE_GB = 5.5;
export const KV_BYTES_PER_TOKEN = 400_000;
export const BYTES_PER_GIB = 1 << 30;
export const COLD_WEIGHT_PAD = 1.2 * (1e9 / BYTES_PER_GIB);
export const PREFILL_BATCH_UNIT_GAIN = 0.25;

export const BATCH_SCALE_AT_4 = {
  gemma_moe: 1.92,
  moe: 3.8,
  dense: 3.2,
} as const;

export type ModelFamily = keyof typeof BATCH_SCALE_AT_4;

export interface FloorTier {
  minGB: number;
  label: string;
  floorUSD: number;
}

// Kept for the existing reference panel; the calculator does not include
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
  minChipGeneration: number;
  sizeGB: number;
  totalParameterCount: number;
  activeParameterCount: number;
  bytesPerParameter: number;
  inputPriceMicroUSDPerMillion: number;
  outputPriceMicroUSDPerMillion: number;
  family: ModelFamily;
  decodeBandwidthEfficiency: number;
}

export type ModelFitReason = "ram" | "chip" | "kv";

function catalogModel(
  spec: Omit<CalculatorModel, "bytesPerParameter">,
): CalculatorModel {
  return {
    ...spec,
    bytesPerParameter: spec.sizeGB / (spec.totalParameterCount / 1_000_000_000),
  };
}

/** Pinned catalog + platform prices. Not fetched live, so the estimate stays stable. */
export const CALCULATOR_MODELS: CalculatorModel[] = [
  catalogModel({
    id: "Qwen3.5-9B",
    displayName: "Qwen 3.5 9B",
    minRAMGB: 24,
    minChipGeneration: 1,
    sizeGB: 6.114,
    totalParameterCount: 9_000_000_000,
    activeParameterCount: 9_000_000_000,
    inputPriceMicroUSDPerMillion: 80_000,
    outputPriceMicroUSDPerMillion: 130_000,
    family: "dense",
    decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
  }),
  catalogModel({
    id: "gpt-oss-20b",
    displayName: "GPT-OSS 20B",
    minRAMGB: 24,
    minChipGeneration: 1,
    sizeGB: 12.104,
    totalParameterCount: 20_000_000_000,
    activeParameterCount: 3_600_000_000,
    inputPriceMicroUSDPerMillion: 20_000,
    outputPriceMicroUSDPerMillion: 100_000,
    family: "moe",
    decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
  }),
  catalogModel({
    id: "gemma-4-26b-qat-4bit",
    displayName: "Gemma 4 26B",
    minRAMGB: 36,
    minChipGeneration: 1,
    sizeGB: 15.641,
    totalParameterCount: 26_000_000_000,
    activeParameterCount: 4_000_000_000,
    inputPriceMicroUSDPerMillion: 42_000,
    outputPriceMicroUSDPerMillion: 220_000,
    family: "gemma_moe",
    decodeBandwidthEfficiency: GEMMA_DECODE_BANDWIDTH_EFFICIENCY,
  }),
  catalogModel({
    id: "EigenLabs/Qwen3.8-27B-4bit-mtp",
    displayName: "Qwen 3.8 27B",
    minRAMGB: 36,
    minChipGeneration: 5,
    sizeGB: 16.32,
    totalParameterCount: 27_000_000_000,
    activeParameterCount: 27_000_000_000,
    inputPriceMicroUSDPerMillion: 150_000,
    outputPriceMicroUSDPerMillion: 2_000_000,
    family: "dense",
    decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
  }),
  catalogModel({
    id: "qwen3-vl-30b-a3b-instruct",
    displayName: "Qwen3-VL 30B A3B Instruct",
    minRAMGB: 32,
    minChipGeneration: 1,
    sizeGB: 18.268,
    totalParameterCount: 30_000_000_000,
    activeParameterCount: 3_000_000_000,
    inputPriceMicroUSDPerMillion: 90_000,
    outputPriceMicroUSDPerMillion: 400_000,
    family: "moe",
    decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
  }),
  catalogModel({
    id: "nvidia-nemotron-3.5-lightning",
    displayName: "Nemotron 3.5 Lightning",
    minRAMGB: 48,
    minChipGeneration: 1,
    sizeGB: 18.544,
    totalParameterCount: 30_000_000_000,
    activeParameterCount: 3_000_000_000,
    inputPriceMicroUSDPerMillion: 65_000,
    outputPriceMicroUSDPerMillion: 180_000,
    family: "moe",
    decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
  }),
  catalogModel({
    id: "qwen3.5-35b-a3b",
    displayName: "Qwen3.5 35B A3B",
    minRAMGB: 36,
    minChipGeneration: 1,
    sizeGB: 20.894,
    totalParameterCount: 35_000_000_000,
    activeParameterCount: 3_000_000_000,
    inputPriceMicroUSDPerMillion: 80_000,
    outputPriceMicroUSDPerMillion: 750_000,
    family: "moe",
    decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
  }),
  catalogModel({
    id: "qwen3.6-35b-a3b-vl-mtp-mxfp8",
    displayName: "Qwen 3.6 35B A3B",
    minRAMGB: 32,
    minChipGeneration: 1,
    sizeGB: 21.309,
    totalParameterCount: 35_000_000_000,
    activeParameterCount: 3_000_000_000,
    inputPriceMicroUSDPerMillion: 50_000,
    outputPriceMicroUSDPerMillion: QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION,
    family: "moe",
    decodeBandwidthEfficiency: DECODE_BANDWIDTH_EFFICIENCY,
  }),
];

export interface CapacityRevenueEstimate {
  model: CalculatorModel;
  activeWeightGBPerToken: number;
  decodeTokensPerSecond: number;
  prefillTokensPerSecond: number;
  maxConcurrency: number;
  effectiveConcurrency: number;
  tokenBudget: number;
  batchedDecodeTokensPerSecond: number;
  batchedPrefillTokensPerSecond: number;
  dutyCyclePercent: number;
  activeSecondsPerMonth: number;
  typicalPromptTokens: number;
  typicalCompletionTokens: number;
  promptTokensPerMonth: number;
  outputTokensPerMonth: number;
  inputPriceUSDPerMillion: number;
  outputPriceUSDPerMillion: number;
  inputRevenueUSD: number;
  outputRevenueUSD: number;
  monthlyRevenueUSD: number;
  annualRevenueUSD: number;
}

export function activeWeightGBPerToken(model: CalculatorModel): number {
  return (model.activeParameterCount * model.bytesPerParameter) / 1_000_000_000;
}

export function singleStreamDecodeTps(
  model: CalculatorModel,
  hardware: HardwareProfile,
): number {
  return (
    (hardware.bandwidthGBs * model.decodeBandwidthEfficiency) /
    activeWeightGBPerToken(model)
  );
}

export function typicalRequestTokens(): number {
  return TYPICAL_PROMPT_TOKENS + TYPICAL_COMPLETION_TOKENS;
}

export function tokenBudgetTokens(memoryGB: number, sizeGB: number): number {
  const weightsGB = sizeGB * COLD_WEIGHT_PAD;
  const postLoadGB = SERVABILITY_CAP_FRACTION * memoryGB - weightsGB;
  if (postLoadGB <= 0) return 0;
  const tokens =
    (postLoadGB * BYTES_PER_GIB - ACTIVATION_RESERVE_GB * BYTES_PER_GIB) /
    KV_BYTES_PER_TOKEN;
  if (tokens <= 0) return 0;
  return Math.floor(tokens);
}

export function chipGeneration(chip: string | undefined): number {
  const match = /^M(\d+)/.exec(chip ?? "");
  return match ? Number(match[1]) : 0;
}

export function modelFit(
  model: CalculatorModel,
  hardware: HardwareProfile,
  memoryGB: number,
): { fits: boolean; reason: ModelFitReason | null } {
  if (memoryGB < model.minRAMGB) return { fits: false, reason: "ram" };
  if (chipGeneration(hardware.chip) < model.minChipGeneration) {
    return { fits: false, reason: "chip" };
  }
  if (tokenBudgetTokens(memoryGB, model.sizeGB) < typicalRequestTokens()) {
    return { fits: false, reason: "kv" };
  }
  return { fits: true, reason: null };
}

export function maxConcurrencyFor(model: CalculatorModel, memoryGB: number): number {
  const budget = tokenBudgetTokens(memoryGB, model.sizeGB);
  const requestTokens = typicalRequestTokens();
  if (budget < requestTokens) return 0;
  return Math.min(ENGINE_MAX_CONCURRENT, Math.floor(budget / requestTokens));
}

export function effectiveConcurrencyFor(
  maxConcurrency: number,
  dutyCyclePercent: number,
): number {
  return 1 + (maxConcurrency - 1) * (dutyCyclePercent / 100);
}

function batchScaleAt4(family: ModelFamily): number {
  switch (family) {
    case "gemma_moe":
      return BATCH_SCALE_AT_4.gemma_moe;
    case "moe":
      return BATCH_SCALE_AT_4.moe;
    case "dense":
      return BATCH_SCALE_AT_4.dense;
  }
}

export function decodeBatchScale(family: ModelFamily, concurrency: number): number {
  if (concurrency <= 1) return 1;
  const unitGain = (batchScaleAt4(family) - 1) / 3;
  return 1 + (concurrency - 1) * unitGain;
}

export function prefillBatchScale(concurrency: number): number {
  if (concurrency <= 1) return 1;
  return 1 + (concurrency - 1) * PREFILL_BATCH_UNIT_GAIN;
}

export function calculateCapacityRevenue(
  model: CalculatorModel,
  hardware: HardwareProfile,
  memoryGB: number,
  dutyCyclePercent = DEFAULT_DUTY_CYCLE_PERCENT,
): CapacityRevenueEstimate | null {
  if (
    !modelFit(model, hardware, memoryGB).fits ||
    model.activeParameterCount <= 0 ||
    model.bytesPerParameter <= 0 ||
    model.inputPriceMicroUSDPerMillion <= 0 ||
    model.outputPriceMicroUSDPerMillion <= 0 ||
    hardware.bandwidthGBs <= 0 ||
    dutyCyclePercent < 0 ||
    dutyCyclePercent > 100
  ) {
    return null;
  }

  const weightGB = activeWeightGBPerToken(model);
  const decodeTokensPerSecond = singleStreamDecodeTps(model, hardware);
  const prefillTokensPerSecond = decodeTokensPerSecond * PREFILL_TO_DECODE_RATIO;
  const tokenBudget = tokenBudgetTokens(memoryGB, model.sizeGB);
  const maxConcurrency = maxConcurrencyFor(model, memoryGB);
  const effectiveConcurrency = effectiveConcurrencyFor(maxConcurrency, dutyCyclePercent);
  const batchedDecodeTokensPerSecond =
    decodeTokensPerSecond * decodeBatchScale(model.family, effectiveConcurrency);
  const batchedPrefillTokensPerSecond =
    prefillTokensPerSecond * prefillBatchScale(effectiveConcurrency);
  if (
    batchedDecodeTokensPerSecond <= 0 ||
    batchedPrefillTokensPerSecond <= 0
  ) {
    return null;
  }

  const requestSeconds =
    TYPICAL_PROMPT_TOKENS / batchedPrefillTokensPerSecond +
    TYPICAL_COMPLETION_TOKENS / batchedDecodeTokensPerSecond;
  const activeSecondsPerMonth = MONTH_SECONDS * (dutyCyclePercent / 100);
  const monthlyRequests = (1 / requestSeconds) * activeSecondsPerMonth;
  const promptTokensPerMonth = monthlyRequests * TYPICAL_PROMPT_TOKENS;
  const outputTokensPerMonth = monthlyRequests * TYPICAL_COMPLETION_TOKENS;
  const inputPriceUSDPerMillion = model.inputPriceMicroUSDPerMillion / 1_000_000;
  const outputPriceUSDPerMillion = model.outputPriceMicroUSDPerMillion / 1_000_000;
  const inputRevenueUSD = (promptTokensPerMonth / 1_000_000) * inputPriceUSDPerMillion;
  const outputRevenueUSD = (outputTokensPerMonth / 1_000_000) * outputPriceUSDPerMillion;
  const monthlyRevenueUSD = inputRevenueUSD + outputRevenueUSD;

  if (!Number.isFinite(monthlyRevenueUSD) || monthlyRevenueUSD < 0) return null;
  return {
    model,
    activeWeightGBPerToken: weightGB,
    decodeTokensPerSecond,
    prefillTokensPerSecond,
    maxConcurrency,
    effectiveConcurrency,
    tokenBudget,
    batchedDecodeTokensPerSecond,
    batchedPrefillTokensPerSecond,
    dutyCyclePercent,
    activeSecondsPerMonth,
    typicalPromptTokens: TYPICAL_PROMPT_TOKENS,
    typicalCompletionTokens: TYPICAL_COMPLETION_TOKENS,
    promptTokensPerMonth,
    outputTokensPerMonth,
    inputPriceUSDPerMillion,
    outputPriceUSDPerMillion,
    inputRevenueUSD,
    outputRevenueUSD,
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
