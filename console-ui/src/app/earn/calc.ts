/**
 * Provider earnings-calculator math.
 *
 * Pure, side-effect-free logic for the /earn calculator. Keep this in sync with
 * the vanilla mirror in landing/earn-calculator.js.
 *
 * Earnings model (see the PR that introduced this for the full rationale):
 *
 *   total = usage + floor − electricity
 *
 *   • usage    — realistic THROUGHPUT at a fixed 80% utilization, where the
 *                throughput credits continuous batching at a quality-preserving
 *                4× (NOT the 16× ceiling the old calculator used — that
 *                overstated earnings by ~10–20×). Utilization and hours are
 *                fixed by product direction and not exposed to the user.
 *   • floor    — the provider base-reward earnings floor (PR #282), set by
 *                verified-memory tier, ramped by uptime. Added ON TOP of usage
 *                (additive), not max(usage, floor).
 *   • elec     — marginal electricity (inference watts over idle) during the
 *                hours the machine is online.
 */

import type { Model, PricingResponse } from "@/lib/api";

/* ─── Hardware database ─── */

export interface MacConfig {
  macType: string;
  chip: string;
  ramOptions: number[];
  bandwidthGBs: number;
  idleWatts: number; // power when model loaded, waiting for requests
  inferWatts: number; // power during active token generation
}

export const MAC_CONFIGS: MacConfig[] = [
  // --- MacBook Air ---
  { macType: "MacBook Air", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 8, inferWatts: 12 },
  { macType: "MacBook Air", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
  { macType: "MacBook Air", chip: "M3", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 8, inferWatts: 12 },
  { macType: "MacBook Air", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 8, inferWatts: 12 },

  // --- MacBook Pro ---
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

  // --- Mac Mini ---
  { macType: "Mac Mini", chip: "M1", ramOptions: [8, 16], bandwidthGBs: 68, idleWatts: 5, inferWatts: 10 },
  { macType: "Mac Mini", chip: "M2", ramOptions: [8, 16, 24], bandwidthGBs: 100, idleWatts: 5, inferWatts: 12 },
  { macType: "Mac Mini", chip: "M2 Pro", ramOptions: [16, 32], bandwidthGBs: 200, idleWatts: 8, inferWatts: 25 },
  { macType: "Mac Mini", chip: "M4", ramOptions: [16, 24, 32], bandwidthGBs: 120, idleWatts: 5, inferWatts: 15 },
  { macType: "Mac Mini", chip: "M4 Pro", ramOptions: [24, 48, 64], bandwidthGBs: 273, idleWatts: 8, inferWatts: 25 },

  // --- Mac Studio ---
  { macType: "Mac Studio", chip: "M1 Max", ramOptions: [32, 64], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: "Mac Studio", chip: "M1 Ultra", ramOptions: [64, 128], bandwidthGBs: 800, idleWatts: 30, inferWatts: 90 },
  { macType: "Mac Studio", chip: "M2 Max", ramOptions: [32, 64, 96], bandwidthGBs: 400, idleWatts: 20, inferWatts: 60 },
  { macType: "Mac Studio", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 35, inferWatts: 100 },
  { macType: "Mac Studio", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819, idleWatts: 35, inferWatts: 110 },
  { macType: "Mac Studio", chip: "M4 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 546, idleWatts: 25, inferWatts: 65 },
  { macType: "Mac Studio", chip: "M5 Max", ramOptions: [36, 48, 64, 128], bandwidthGBs: 600, idleWatts: 25, inferWatts: 65 },

  // --- Mac Pro ---
  { macType: "Mac Pro", chip: "M2 Ultra", ramOptions: [64, 128, 192], bandwidthGBs: 800, idleWatts: 40, inferWatts: 120 },
  { macType: "Mac Pro", chip: "M3 Ultra", ramOptions: [96, 256, 512], bandwidthGBs: 819, idleWatts: 40, inferWatts: 120 },
];

export const MAC_TYPES = ["MacBook Air", "MacBook Pro", "Mac Mini", "Mac Studio", "Mac Pro"];

/* ─── Tunable model constants ─── */

export const DEFAULT_OUTPUT_PRICE_MICRO_USD = 200_000; // $0.20 / 1M output tokens
export const DEFAULT_INPUT_PRICE_MICRO_USD = 50_000; // $0.05 / 1M input tokens

/**
 * Sustained fraction of peak unified-memory bandwidth a single decode stream
 * achieves. Memory-bandwidth-bound decode reads the active weights once per
 * token; 0.60 is a conservative midpoint of observed efficiency.
 */
export const SINGLE_STREAM_EFFICIENCY = 0.6;

/**
 * Continuous-batching gain over single-stream at quality-preserving
 * concurrency (provider-swift BatchScheduler sustains multiple requests in a
 * single fused decode step without dropping per-user latency). Capped at 4× —
 * NOT the theoretical 16× ceiling — to stay within the concurrency the engine
 * holds while keeping decode latency acceptable.
 */
export const CONTINUOUS_BATCH_FACTOR = 4;

/**
 * Assumed network utilization (fraction of time the machine is actively
 * serving a request while online). 100% would mean a request every second;
 * 80% leaves realistic idle gaps between requests at the demand level the
 * calculator targets. Fixed by product direction — not exposed to the user.
 */
export const ASSUMED_UTILIZATION = 0.8;

/**
 * Network-observed prompt:completion token ratio (≈3.5:1 from /v1/stats:
 * total_prompt_tokens / total_completion_tokens). Decode throughput limits
 * completion tokens; the matching prompt tokens are prefilled "for free"
 * (prefill is far faster than decode) and are also billed, so we credit input
 * revenue at this ratio.
 */
export const PROMPT_TO_COMPLETION_RATIO = 3.5;

/* ─── Base-reward earnings floor (PR #282) ─── */

export interface FloorTier {
  minGB: number;
  label: string;
  floorUSD: number;
}

/**
 * Provider base-reward floor by verified unified-memory tier (USD/mo).
 * Mirrors coordinator/payments/baserewards/floor.go (floorTiers). A machine is
 * paid the floor of the largest tier whose minGB it meets; sub-24GB earns $0.
 */
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

/** Uptime fraction below which the floor is 0; it ramps linearly to full at 100%. */
export const MIN_UPTIME_FOR_AVAIL = 0.9;

/** Monthly floor (USD) for a verified memory size, before availability/taper. */
export function tierFloorUSD(memGB: number): number {
  for (const t of FLOOR_TIERS) {
    if (memGB >= t.minGB) return t.floorUSD;
  }
  return 0;
}

/**
 * Availability multiplier for a monthly uptime fraction: clamp((u-0.90)/0.10,0,1).
 * 0 at/below 90% uptime, 1.0 at 100%. Mirrors baserewards.Avail.
 */
export function availFromUptime(uptimeFrac: number): number {
  const v = (uptimeFrac - MIN_UPTIME_FOR_AVAIL) / (1 - MIN_UPTIME_FOR_AVAIL);
  if (v < 0) return 0;
  if (v > 1) return 1;
  return v;
}

/** Per-machine monthly floor (USD): tier × availability × taper. taper=1 today. */
export function scaledFloorUSD(memGB: number, uptimeFrac: number, taper = 1): number {
  return tierFloorUSD(memGB) * availFromUptime(uptimeFrac) * taper;
}

/* ─── Live model catalog ─── */

export interface CatalogModel {
  id: string;
  name: string;
  minRAMGB: number;
  demandNote: string;
  activeParamsGB: number;
  modelSizeGB: number;
  outputPriceMicro: number;
  inputPriceMicro: number;
}

interface PriceLookupEntry {
  output: number;
  input: number;
}

export function buildPricingLookup(pricing: PricingResponse | null): Record<string, PriceLookupEntry> {
  if (!pricing) return {};
  return Object.fromEntries(
    pricing.prices.map((p) => [p.model, { output: p.output_price, input: p.input_price }])
  );
}

export function modelSizeGB(model: Model): number {
  if (model.size_gb && model.size_gb > 0) return model.size_gb;
  if (model.size_bytes && model.size_bytes > 0) return model.size_bytes / 1e9;
  const match = model.id.match(/(?:^|[^A-Za-z0-9])(\d{1,3})\s*[bB](?:[^A-Za-z0-9]|$)/);
  return match ? Number(match[1]) : 27;
}

export function activeParamsGB(model: Model, sizeGB: number): number {
  // Search id, architecture, and description; accept decimal active counts
  // ("A3.6B" or "3.6B active") before falling back to the size-based estimate.
  const text = `${model.id} ${model.architecture ?? ""} ${model.description ?? ""}`;
  const active = text.match(/A(\d{1,3}(?:\.\d+)?)B/i) ?? text.match(/(\d{1,3}(?:\.\d+)?)B\s+active/i);
  if (active) return Math.max(1, Math.round(Number(active[1])));
  if (/moe/i.test(text)) return Math.max(3, Math.round(sizeGB * 0.15));
  return Math.max(1, Math.round(sizeGB));
}

/**
 * Strip known quantization / build-variant suffixes from a model id to get its
 * base-model key. e.g. "gemma-4-26b-qat-4bit" / "gemma-4-26b-8bit" →
 * "gemma-4-26b". Used to collapse catalog variants of the same model.
 */
export function baseModelKey(id: string): string {
  let k = id.toLowerCase().trim();
  const suffix = /-(qat|q4|q8|int4|int8|4bit|8bit|4-bit|8-bit|bf16|fp16|mxfp4|nf4|gguf|rollback|preview|beta|rc\d*)$/;
  let prev = "";
  while (k !== prev) {
    prev = k;
    k = k.replace(suffix, "");
  }
  return k;
}

/** Lower is more canonical — prefer clean names / base ids over quant/rollback builds. */
function variantPenalty(m: Model): number {
  const text = `${m.display_name ?? ""} ${m.id}`.toLowerCase();
  let p = 0;
  if (/\(|rollback|preview|\brc\b/.test(text)) p += 100; // explicit variant/rollback build
  if (/qat|int4|int8|fp16|bf16|mxfp4|nf4|\d\s*-?bit/.test(text)) p += 10; // quantization suffix
  p += m.id.length * 0.01; // tie-break: shorter (base) id wins
  return p;
}

/**
 * Collapse catalog variants (different quantizations / rollback builds of the
 * same base model) into one entry, keeping the most canonical build. The live
 * catalog lists e.g. gemma-4-26b, gemma-4-26b-qat-4bit and gemma-4-26b-8bit as
 * separate rows; the earnings calculator should show a single "Gemma 4 26B".
 */
export function dedupeModelVariants(models: Model[]): Model[] {
  const byBase = new Map<string, Model>();
  for (const m of models) {
    const key = baseModelKey(m.id);
    const cur = byBase.get(key);
    if (!cur || variantPenalty(m) < variantPenalty(cur)) byBase.set(key, m);
  }
  return [...byBase.values()];
}

export function buildCatalogModels(models: Model[], pricing: PricingResponse | null): CatalogModel[] {
  const prices = buildPricingLookup(pricing);
  return dedupeModelVariants(models)
    .map((model) => {
      const price = prices[model.id];
      const size = Math.max(1, Math.round(modelSizeGB(model)));
      return {
        id: model.id,
        name: model.display_name || model.id.split("/").pop() || model.id,
        minRAMGB: model.min_ram_gb || Math.ceil(size * 1.35),
        demandNote: "Uses the live coordinator catalog and current/default per-token pricing.",
        activeParamsGB: activeParamsGB(model, size),
        modelSizeGB: size,
        outputPriceMicro: price?.output ?? DEFAULT_OUTPUT_PRICE_MICRO_USD,
        inputPriceMicro: price?.input ?? DEFAULT_INPUT_PRICE_MICRO_USD,
      };
    })
    .filter((model): model is CatalogModel => Boolean(model));
}

/* ─── Earnings calculation ─── */

export interface ModelEarnings {
  modelId: string;
  modelName: string;
  decodeTokPerSec: number; // single-stream decode throughput
  revenuePerHour: number; // usage revenue (output + input tokens)
  elecPerHour: number;
  netPerHour: number; // usage net (revenue − elec), excludes floor
  monthlyRevenue: number;
  monthlyElec: number;
  monthlyNet: number; // usage net, excludes floor
  elecPercent: number;
  activeParamsGB: number;
  outputPriceMicro: number;
  inputPriceMicro: number;
  marginalWatts: number;
  catalogModel: CatalogModel;
}

/**
 * Per-model USAGE earnings at 100% utilization for `hoursOnlinePerDay` hours/day.
 * Single-stream throughput, no batch multiplier. The base-reward floor is added
 * separately at the portfolio level (it is per-machine, not per-model).
 */
export function calculateModelEarnings(
  model: CatalogModel,
  config: MacConfig,
  hoursOnlinePerDay: number,
  elecCostPerKWh: number
): ModelEarnings {
  const { activeParamsGB, outputPriceMicro, inputPriceMicro } = model;

  // Effective decode throughput = single-stream × continuous batch × assumed
  // utilization. The batch factor (4×) credits the engine's continuous batching
  // at quality-preserving concurrency; the utilization (80%) leaves realistic
  // idle gaps. See file header.
  const singleTokPerSec = (config.bandwidthGBs / activeParamsGB) * SINGLE_STREAM_EFFICIENCY;
  const decodeTokPerSec =
    singleTokPerSec * CONTINUOUS_BATCH_FACTOR * ASSUMED_UTILIZATION;
  const completionTokPerHour = decodeTokPerSec * 3600;
  const promptTokPerHour = completionTokPerHour * PROMPT_TO_COMPLETION_RATIO;
  const revenuePerHour =
    (completionTokPerHour / 1_000_000) * (outputPriceMicro / 1_000_000) +
    (promptTokPerHour / 1_000_000) * (inputPriceMicro / 1_000_000);

  // Marginal electricity: the machine is actually inferring at `utilization`
  // of online time; the rest it sits at idle (no marginal draw).
  const marginalWatts = config.inferWatts - config.idleWatts;
  const elecPerHour = (marginalWatts / 1000) * elecCostPerKWh * ASSUMED_UTILIZATION;
  const netPerHour = revenuePerHour - elecPerHour;

  const hoursPerMonth = hoursOnlinePerDay * 30;
  const monthlyRevenue = revenuePerHour * hoursPerMonth;
  const monthlyElec = elecPerHour * hoursPerMonth;
  const monthlyNet = netPerHour * hoursPerMonth;
  const elecPercent = monthlyRevenue > 0 ? (monthlyElec / monthlyRevenue) * 100 : 0;

  return {
    modelId: model.id,
    modelName: model.name,
    decodeTokPerSec,
    revenuePerHour,
    elecPerHour,
    netPerHour,
    monthlyRevenue,
    monthlyElec,
    monthlyNet,
    elecPercent,
    activeParamsGB,
    outputPriceMicro,
    inputPriceMicro,
    marginalWatts,
    catalogModel: model,
  };
}

export interface PortfolioEarnings {
  modelName: string;
  selectedModels: ModelEarnings[];
  selectedModelCount: number;
  totalModelSizeGB: number;
  hoursPerModel: number;
  decodeTokPerSec: number;

  // Usage (organic inference)
  monthlyRevenue: number;
  monthlyElec: number;
  monthlyUsageNet: number; // usage revenue − electricity (excludes floor)
  revenuePerHour: number;
  elecPerHour: number;
  netPerHour: number; // usage net per active hour (excludes floor)
  elecPercent: number;

  // Base-reward floor (additive)
  memoryGB: number;
  uptimeFrac: number;
  monthlyFloor: number;

  // Totals (usage + floor − elec)
  monthlyNet: number;
  annualNet: number;
}

/**
 * Portfolio earnings = Σ per-model usage (selected models share the active
 * hours) PLUS the per-machine base-reward floor, minus electricity.
 *
 *   total = usage + floor − elec
 */
export function calculatePortfolioEarnings(
  models: CatalogModel[],
  config: MacConfig,
  ramGB: number,
  hoursOnlinePerDay: number,
  elecCostPerKWh: number
): PortfolioEarnings | null {
  if (models.length === 0) return null;
  const totalModelSizeGB = models.reduce((sum, model) => sum + model.modelSizeGB, 0);
  if (totalModelSizeGB > ramGB) return null;

  const hoursPerModel = hoursOnlinePerDay / models.length;
  const selectedModels = models.map((model) =>
    calculateModelEarnings(model, config, hoursPerModel, elecCostPerKWh)
  );

  const monthlyRevenue = selectedModels.reduce((sum, m) => sum + m.monthlyRevenue, 0);
  const monthlyElec = selectedModels.reduce((sum, m) => sum + m.monthlyElec, 0);
  const monthlyUsageNet = monthlyRevenue - monthlyElec;

  // Base-reward floor: per-machine, set by verified memory + uptime. The
  // machine is assumed online `hoursOnlinePerDay` hours/day → uptime fraction.
  const uptimeFrac = Math.min(1, hoursOnlinePerDay / 24);
  const monthlyFloor = scaledFloorUSD(ramGB, uptimeFrac);

  const monthlyNet = monthlyUsageNet + monthlyFloor;
  const activeHoursPerMonth = Math.max(1, hoursOnlinePerDay * 30);

  return {
    modelName: models.length === 1 ? models[0].name : `${models.length} models selected`,
    selectedModels,
    selectedModelCount: models.length,
    totalModelSizeGB,
    hoursPerModel,
    decodeTokPerSec:
      selectedModels.reduce((sum, m) => sum + m.decodeTokPerSec, 0) / selectedModels.length,
    monthlyRevenue,
    monthlyElec,
    monthlyUsageNet,
    revenuePerHour: monthlyRevenue / activeHoursPerMonth,
    elecPerHour: monthlyElec / activeHoursPerMonth,
    netPerHour: monthlyUsageNet / activeHoursPerMonth,
    elecPercent: monthlyRevenue > 0 ? (monthlyElec / monthlyRevenue) * 100 : 0,
    memoryGB: ramGB,
    uptimeFrac,
    monthlyFloor,
    monthlyNet,
    annualNet: monthlyNet * 12,
  };
}

/* ─── Fun comparisons ─── */

export function getComparisons(monthlyNet: number): string[] {
  const comparisons: string[] = [];
  if (monthlyNet > 2) comparisons.push(`${Math.floor(monthlyNet / 2)} Spotify Premium subscriptions`);
  if (monthlyNet > 5) comparisons.push(`${Math.floor(monthlyNet / 5)} lattes per month`);
  if (monthlyNet > 15) comparisons.push(`${Math.floor(monthlyNet / 15)} Netflix Standard plans`);
  if (monthlyNet > 50) comparisons.push(`a ${Math.floor(monthlyNet / 50)}-day parking meter`);
  if (monthlyNet > 70) comparisons.push(`${Math.floor(monthlyNet / 70)}x your home internet bill`);
  if (monthlyNet > 200)
    comparisons.push(
      `$${(monthlyNet * 12).toLocaleString(undefined, { maximumFractionDigits: 0 })}/yr — a nice side income`
    );
  return comparisons;
}

/* ─── Format helpers ─── */

export function fmtUSD(n: number, decimals = 2): string {
  if (n < 0) return "-$" + Math.abs(n).toFixed(decimals);
  return "$" + n.toFixed(decimals);
}

export function fmtUSDWhole(n: number): string {
  if (n < 0) return "-$" + Math.abs(n).toLocaleString(undefined, { maximumFractionDigits: 0 });
  return "$" + n.toLocaleString(undefined, { maximumFractionDigits: 0 });
}
