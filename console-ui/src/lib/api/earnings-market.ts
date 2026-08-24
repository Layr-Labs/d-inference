import type {
  BaseRewardTier,
  EarningsMarketAudit,
  EarningsMarketBaseRewards,
  EarningsMarketModel,
  EarningsMarketResponse,
  EarningsUnavailableReason,
} from "./types";

type JsonRecord = Record<string, unknown>;

const WINDOW_MS = 30 * 24 * 60 * 60 * 1000;
const INVALID_MARKET_RESPONSE = "Invalid earnings market response";
export const EARNINGS_MARKET_TIMEOUT_MS = 10_000;
const UNAVAILABLE_REASONS = new Set<EarningsUnavailableReason>([
  "settled_work_unavailable",
  "competing_capacity_unavailable",
  "throughput_benchmark_unavailable",
]);

function asRecord(value: unknown): JsonRecord | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : null;
}

function isNonNegativeNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value >= 0;
}

function isNonNegativeInteger(value: unknown): value is number {
  return isNonNegativeNumber(value) && Number.isSafeInteger(value);
}

function isPositiveInteger(value: unknown): value is number {
  return isNonNegativeInteger(value) && value > 0;
}

function expectedUnavailableReason(
  model: JsonRecord,
): EarningsUnavailableReason | null {
  if (
    !isNonNegativeInteger(model.work_payout_micro_usd) ||
    !isNonNegativeInteger(model.paid_tokens) ||
    !isNonNegativeInteger(model.paid_jobs) ||
    model.work_payout_micro_usd <= 0 ||
    model.paid_tokens <= 0 ||
    model.paid_jobs <= 0
  ) {
    return "settled_work_unavailable";
  }
  if (
    !isNonNegativeNumber(model.aggregate_tps) ||
    !isNonNegativeInteger(model.provider_supply) ||
    model.aggregate_tps <= 0 ||
    model.provider_supply <= 0
  ) {
    return "competing_capacity_unavailable";
  }
  if (
    !isNonNegativeNumber(model.benchmark_tps) ||
    !isNonNegativeNumber(model.benchmark_memory_bandwidth_gbps) ||
    model.benchmark_tps <= 0 ||
    model.benchmark_memory_bandwidth_gbps <= 0
  ) {
    return "throughput_benchmark_unavailable";
  }
  return null;
}

function isMarketModel(value: unknown): value is EarningsMarketModel {
  const model = asRecord(value);
  if (
    !model ||
    typeof model.id !== "string" ||
    model.id.length === 0 ||
    typeof model.display_name !== "string" ||
    model.display_name.length === 0 ||
    !isPositiveInteger(model.min_ram_gb) ||
    !isPositiveInteger(model.size_bytes) ||
    !isNonNegativeNumber(model.size_gb) ||
    model.size_gb <= 0 ||
    !isNonNegativeInteger(model.work_payout_micro_usd) ||
    !isNonNegativeInteger(model.paid_tokens) ||
    !isNonNegativeInteger(model.paid_jobs) ||
    !isNonNegativeNumber(model.aggregate_tps) ||
    !isNonNegativeNumber(model.aggregate_memory_bandwidth_gbps) ||
    !isNonNegativeNumber(model.benchmark_tps) ||
    !isNonNegativeNumber(model.benchmark_memory_bandwidth_gbps) ||
    !isNonNegativeInteger(model.provider_supply) ||
    typeof model.estimate_available !== "boolean"
  ) {
    return false;
  }
  const expected = expectedUnavailableReason(model);
  if (model.estimate_available) {
    return expected === null && model.unavailable_reason === undefined;
  }
  return (
    expected !== null &&
    typeof model.unavailable_reason === "string" &&
    UNAVAILABLE_REASONS.has(model.unavailable_reason as EarningsUnavailableReason) &&
    model.unavailable_reason === expected
  );
}

function isAudit(value: unknown): value is EarningsMarketAudit {
  const audit = asRecord(value);
  if (!audit) return false;
  if (
    !isNonNegativeInteger(audit.total_settled_work_micro_usd) ||
    !isNonNegativeInteger(audit.modeled_work_micro_usd) ||
    !isNonNegativeInteger(audit.unattributed_work_micro_usd) ||
    !isNonNegativeInteger(audit.total_paid_tokens) ||
    !isNonNegativeInteger(audit.modeled_paid_tokens) ||
    !isNonNegativeInteger(audit.unattributed_paid_tokens) ||
    !isNonNegativeInteger(audit.total_paid_jobs) ||
    !isNonNegativeInteger(audit.modeled_paid_jobs) ||
    !isNonNegativeInteger(audit.unattributed_paid_jobs)
  ) {
    return false;
  }
  const typed = audit as unknown as EarningsMarketAudit;
  return (
    typed.modeled_work_micro_usd + typed.unattributed_work_micro_usd ===
      typed.total_settled_work_micro_usd &&
    typed.modeled_paid_tokens + typed.unattributed_paid_tokens === typed.total_paid_tokens &&
    typed.modeled_paid_jobs + typed.unattributed_paid_jobs === typed.total_paid_jobs
  );
}

function isBaseRewardTier(value: unknown): value is BaseRewardTier {
  const tier = asRecord(value);
  return Boolean(
    tier &&
      isPositiveInteger(tier.min_ram_gb) &&
      isNonNegativeInteger(tier.monthly_micro_usd),
  );
}

function isBaseRewards(value: unknown): value is EarningsMarketBaseRewards {
  const policy = asRecord(value);
  if (
    !policy ||
    typeof policy.enabled !== "boolean" ||
    !isNonNegativeInteger(policy.monthly_pool_micro_usd) ||
    !isNonNegativeNumber(policy.min_uptime_fraction) ||
    policy.min_uptime_fraction > 1 ||
    !isNonNegativeNumber(policy.reduction_k) ||
    !isNonNegativeNumber(policy.account_cap_fraction) ||
    policy.account_cap_fraction > 1 ||
    !Array.isArray(policy.tiers) ||
    policy.tiers.length === 0 ||
    !policy.tiers.every(isBaseRewardTier)
  ) {
    return false;
  }
  const minRAMValues = policy.tiers.map((tier) => tier.min_ram_gb);
  return new Set(minRAMValues).size === minRAMValues.length;
}

export function parseEarningsMarket(value: unknown): EarningsMarketResponse {
  const market = asRecord(value);
  const start = typeof market?.window_start === "string" ? Date.parse(market.window_start) : NaN;
  const end = typeof market?.window_end === "string" ? Date.parse(market.window_end) : NaN;
  if (
    !market ||
    market.window_days !== 30 ||
    !Number.isFinite(start) ||
    !Number.isFinite(end) ||
    end - start !== WINDOW_MS ||
    !Array.isArray(market.models) ||
    market.models.length === 0 ||
    !market.models.every(isMarketModel) ||
    !isAudit(market.audit) ||
    !isBaseRewards(market.base_rewards)
  ) {
    throw new Error(INVALID_MARKET_RESPONSE);
  }

  const models = market.models as EarningsMarketModel[];
  if (new Set(models.map((model) => model.id)).size !== models.length) {
    throw new Error(INVALID_MARKET_RESPONSE);
  }
  const audit = market.audit as unknown as EarningsMarketAudit;
  const modeledWork = models.reduce((sum, model) => sum + model.work_payout_micro_usd, 0);
  const modeledTokens = models.reduce((sum, model) => sum + model.paid_tokens, 0);
  const modeledJobs = models.reduce((sum, model) => sum + model.paid_jobs, 0);
  if (
    modeledWork !== audit.modeled_work_micro_usd ||
    modeledTokens !== audit.modeled_paid_tokens ||
    modeledJobs !== audit.modeled_paid_jobs
  ) {
    throw new Error(INVALID_MARKET_RESPONSE);
  }
  return market as unknown as EarningsMarketResponse;
}

export async function fetchEarningsMarket(): Promise<EarningsMarketResponse> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), EARNINGS_MARKET_TIMEOUT_MS);
  try {
    const response = await fetch("/api/earnings/market", {
      headers: { Accept: "application/json" },
      signal: controller.signal,
    });
    if (!response.ok) {
      throw new Error(`Failed to fetch earnings market: ${response.status}`);
    }
    return parseEarningsMarket(await response.json());
  } finally {
    clearTimeout(timeout);
  }
}
