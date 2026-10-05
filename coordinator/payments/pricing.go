package payments

import (
	"strconv"
	"strings"

	microusd "github.com/eigeninference/d-inference/coordinator/internal/payments/microusd"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Pricing model for Darkbloom.
//
// All model-specific prices are managed via the admin API:
//
//	PUT /v1/admin/pricing  {"model":"...", "input_price":..., "output_price":..., "cache_read_price":...}
//
// Prices are stored in the database (model_prices table, account_id="platform").
// The billing path resolves prices in order:
//  1. Provider custom price  (store.GetModelPrice(providerAccountID, model))
//  2. Platform admin price   (store.GetModelPrice("platform", model))
//  3. Fallback defaults      (constants below)
//
// The fallback defaults apply only to models that have not been priced via API.
// All prices are in micro-USD per 1M tokens.
//
// A request's prompt tokens split into two SKUs. Tokens the provider prefilled
// bill at the input price; tokens it served from its prefix cache (the
// consumer-visible usage.prompt_tokens_details.cached_tokens) bill at the
// cache-read price — OpenRouter's pricing.input_cache_read. Caching is
// provider-initiated and never requested, so there is no cache-write SKU.

// DefaultInputPricePerMillion is the fallback input price for models without
// DB-configured pricing (micro-USD per 1M tokens). $0.05 per 1M tokens.
const DefaultInputPricePerMillion int64 = 50_000

// DefaultOutputPricePerMillion is the fallback output price for models without
// DB-configured pricing (micro-USD per 1M tokens). $0.20 per 1M tokens.
const DefaultOutputPricePerMillion int64 = 200_000

// DefaultCacheReadDiscountPercent is the discount off the input price that
// cached prompt tokens receive when a price row sets no explicit
// cache_read_price. A cache hit skips the prefill compute for the matched
// prefix, so cached tokens cost the provider a fraction of an uncached token;
// 50% is the conservative industry baseline (OpenAI's standard prompt-caching
// discount). Operators set a per-model cache_read_price to move off it.
const DefaultCacheReadDiscountPercent int64 = 50

// Minimum charge per inference request in micro-USD ($0.0001).
const minimumChargeMicroUSD int64 = 100

// Platform fee percentage — the global default routing fee applied when an
// account has no per-account override. Set to 0 for the public alpha so
// providers keep 100% of revenue (matches the README / landing copy). Raise
// this post-alpha; per-account overrides via PUT /v1/admin/users/platform-fee
// still apply on top of the default.
//
// NOTE: the referral program pays out a share of this platform fee, so while
// the default is 0 there is no fee pool to distribute (referrals are dormant
// during the alpha).
const platformFeePercent int64 = 0

// MinimumCharge returns the minimum charge per inference request in micro-USD.
func MinimumCharge() int64 {
	return minimumChargeMicroUSD
}

// Rates are the settlement prices of one model for one payer, in micro-USD per
// 1,000,000 tokens. Every reader of a price row goes through RatesFor so the
// derived cache-read default is applied in exactly one place.
type Rates struct {
	Input     int64 // prompt tokens the provider prefilled
	Output    int64 // completion tokens
	CacheRead int64 // prompt tokens the provider served from its prefix cache
}

// Usage is the billable token breakdown of a completed request. CachedTokens
// is a subset of PromptTokens, never additional to it, matching the OpenAI
// usage shape the consumer sees (prompt_tokens includes cached_tokens).
type Usage struct {
	PromptTokens     int
	CachedTokens     int
	CompletionTokens int
}

// DefaultCacheReadPrice derives the cache-read rate of a price row that sets
// none: the input price less DefaultCacheReadDiscountPercent, floored. The
// product is split around /100 so an input price near math.MaxInt64 cannot
// wrap into a negative rate; a non-positive input price derives 0.
func DefaultCacheReadPrice(inputPerMillion int64) int64 {
	if inputPerMillion <= 0 {
		return 0
	}
	const keep = 100 - DefaultCacheReadDiscountPercent
	return inputPerMillion/100*keep + inputPerMillion%100*keep/100
}

// DefaultRates are the rates of a model with no configured price row.
func DefaultRates() Rates {
	return RatesFor(store.ModelPrice{
		InputPrice:  DefaultInputPricePerMillion,
		OutputPrice: DefaultOutputPricePerMillion,
	}, true)
}

// RatesFor resolves a price row into settlement rates. configured is the ok
// value of the store lookup; false yields DefaultRates. A row without an
// explicit CacheReadPrice bills cached tokens at DefaultCacheReadPrice of its
// own input price, so the discount tracks the input price wherever it is set.
func RatesFor(price store.ModelPrice, configured bool) Rates {
	if !configured {
		return DefaultRates()
	}
	r := Rates{Input: price.InputPrice, Output: price.OutputPrice}
	if price.CacheReadPrice != nil {
		r.CacheRead = *price.CacheReadPrice
	} else {
		r.CacheRead = DefaultCacheReadPrice(price.InputPrice)
	}
	return r
}

// Cost is the exact per-token cost in micro-USD with no per-request floor:
// uncached prompt tokens at Input, cached prompt tokens at CacheRead, and
// completion tokens at Output, each term floored to whole micro-USD. Used for
// service/wholesale channels (e.g. OpenRouter) whose advertised pricing is
// purely per-token (request price = 0), so the debit must equal the published
// per-token math exactly rather than being floored. Nonzero usage is never
// free: a request whose exact cost rounds to 0 is charged 1 micro-USD.
//
// Token counts are provider-reported and untrusted. Malformed usage cannot
// produce a negative or wrapped charge: negative counts and rates bill as 0,
// CachedTokens is clamped to PromptTokens, and every product saturates at
// math.MaxInt64 instead of overflowing — an absurd count then meets the
// settlement overage clamp (≤ 2× the reservation) rather than turning a
// wrapped negative cost into a refund.
func (r Rates) Cost(u Usage) int64 {
	prompt := max(u.PromptTokens, 0)
	cached := min(max(u.CachedTokens, 0), prompt)
	completion := max(u.CompletionTokens, 0)

	cost := microusd.Add(
		microusd.Add(microusd.TermCost(prompt-cached, r.Input), microusd.TermCost(cached, r.CacheRead)),
		microusd.TermCost(completion, r.Output))
	if cost == 0 && (prompt > 0 || completion > 0) {
		cost = 1
	}
	return cost
}

// CostWithMinimum is Cost floored at MinimumCharge, the per-request minimum
// applied to direct consumers.
func (r Rates) CostWithMinimum(u Usage) int64 {
	return max(r.Cost(u), minimumChargeMicroUSD)
}

// CacheReadDiscount is how much less cost charges for u than for the same
// request with every prompt token at the input rate — the revenue effect of
// the cache hit, in micro-USD. cost is the settlement function actually used
// (Rates.Cost or Rates.CostWithMinimum), so a request whose cold and warm
// costs both sit at the per-request minimum reports no discount.
func CacheReadDiscount(cost func(Usage) int64, u Usage) int64 {
	cold := u
	cold.CachedTokens = 0
	return max(cost(cold)-cost(u), 0)
}

// DefaultPlatformFeePercent is the global platform routing fee applied when an
// account has no per-account override.
const DefaultPlatformFeePercent int64 = platformFeePercent

// resolveFeePercent clamps an optional per-account fee override to [0,100],
// falling back to the global default when feePercent is nil.
func resolveFeePercent(feePercent *int64) int64 {
	pct := platformFeePercent
	if feePercent != nil {
		pct = *feePercent
	}
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return pct
}

// PlatformFee returns Darkbloom's routing fee at the global default rate.
func PlatformFee(totalCost int64) int64 {
	return PlatformFeeWithPercent(totalCost, nil)
}

// ProviderPayout returns the amount the provider receives at the global default
// fee rate.
func ProviderPayout(totalCost int64) int64 {
	return ProviderPayoutWithPercent(totalCost, nil)
}

// PlatformFeeWithPercent returns Darkbloom's routing fee using a per-account
// override when provided (nil = global default). A 0% override yields no fee.
func PlatformFeeWithPercent(totalCost int64, feePercent *int64) int64 {
	return totalCost * resolveFeePercent(feePercent) / 100
}

// ProviderPayoutWithPercent returns the amount the provider receives after the
// (possibly overridden) platform fee.
func ProviderPayoutWithPercent(totalCost int64, feePercent *int64) int64 {
	return totalCost - PlatformFeeWithPercent(totalCost, feePercent)
}

// FormatPerTokenUSD converts a price expressed in micro-USD per 1,000,000
// tokens into a plain decimal USD-per-single-token string, as required by the
// OpenRouter provider /v1/models schema (e.g. 50000 -> "0.00000005").
//
// micro-USD per 1M tokens / 1e6 (micro->USD) / 1e6 (per-1M->per-token) = value / 1e12.
// We render with fixed precision and trim trailing zeros, always leaving at
// least one digit after the decimal point so the value stays a valid number
// string ("0" stays "0").
func FormatPerTokenUSD(microUSDPerMillion int64) string {
	if microUSDPerMillion == 0 {
		return "0"
	}
	// Scale to USD-per-token: divide by 1e12. Use big-enough fixed precision
	// (12 decimals captures the full micro-USD resolution).
	s := strconv.FormatFloat(float64(microUSDPerMillion)/1e12, 'f', 12, 64)
	// Trim trailing zeros but keep a leading integer digit.
	if strings.Contains(s, ".") {
		s = strings.TrimRight(s, "0")
		s = strings.TrimSuffix(s, ".")
	}
	if s == "" || s == "-" {
		return "0"
	}
	return s
}

// FormatPerMillionUSD renders a micro-USD-per-1M-token price as the
// "$0.0500" style USD-per-1M string used by GET /v1/pricing and the pricing
// admin responses.
func FormatPerMillionUSD(microUSDPerMillion int64) string {
	return "$" + strconv.FormatFloat(float64(microUSDPerMillion)/1_000_000, 'f', 4, 64)
}
