export interface Hardware {
  id: string;
  macType: string;
  chip: string;
  ramOptions: number[];
  bandwidthGBs: number;
}
export interface CalculatorModel {
  id: string;
  displayName: string;
  minRAMGB: number;
  sizeGB: number;
  activeParameterCount: number;
  bytesPerParameter: number;
  outputPriceMicroUSDPerMillion: number;
}
export interface Revenue {
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
export const DEFAULT_DUTY_CYCLE_PERCENT: number;
export const DECODE_BANDWIDTH_EFFICIENCY: number;
export const MIN_PROVIDER_MEMORY_GB: number;
export const QWEN_OUTPUT_PRICE_MICRO_USD_PER_MILLION: number;
export const HARDWARE_OPTIONS: Hardware[];
export const PROVIDER_HARDWARE_OPTIONS: Hardware[];
export const CALCULATOR_MODELS: CalculatorModel[];
export function calculateCapacityRevenue(
  model: CalculatorModel,
  hardware: Hardware,
  memoryGB: number,
  dutyCyclePercent?: number,
): Revenue | null;
