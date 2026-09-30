// Coordinator pricing defaults mirrored for display. Source of truth:
// coordinator/payments/pricing.go.

// Fallback rates when a model has no platform price row
// (payments.DefaultInputPricePerMillion / DefaultOutputPricePerMillion).
export const DEFAULT_INPUT_PRICE_MICRO = 50_000;
export const DEFAULT_OUTPUT_PRICE_MICRO = 200_000;

// Discount off the input price for cached prompt tokens when a row sets no
// cache_read_price (payments.DefaultCacheReadDiscountPercent).
export const DEFAULT_CACHE_READ_DISCOUNT_PERCENT = 50;

// Mirrors payments.DefaultCacheReadPrice: the cache-read rate the coordinator
// bills when the platform row (or the fallback) sets no explicit one. Integer
// micro-USD, floored like the Go arithmetic. inputMicro is the row's BIGINT as
// pg returns it (string) or null when the model has no price row.
export function derivedCacheReadMicro(inputMicro: string | null): number {
  const parsed = inputMicro != null && inputMicro !== "" ? Number(inputMicro) : DEFAULT_INPUT_PRICE_MICRO;
  const base = Number.isFinite(parsed) ? parsed : DEFAULT_INPUT_PRICE_MICRO;
  return Math.floor((base * (100 - DEFAULT_CACHE_READ_DISCOUNT_PERCENT)) / 100);
}
