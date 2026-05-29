package payments

import (
	"strconv"
	"strings"
)

// Pricing model for Darkbloom.
//
// All model-specific prices are managed via the admin API:
//
//   PUT /v1/admin/pricing  {"model":"...", "input_price":..., "output_price":...}
//
// Prices are stored in the database (model_prices table, account_id="platform").
// The billing path resolves prices in order:
//   1. Provider custom price  (store.GetModelPrice(providerAccountID, model))
//   2. Platform admin price   (store.GetModelPrice("platform", model))
//   3. Fallback defaults      (constants below)
//
// The fallback defaults apply only to models that have not been priced via API.
// All prices are in micro-USD per 1M tokens.

// DefaultInputPricePerMillion is the fallback input price for models without
// DB-configured pricing (micro-USD per 1M tokens). $0.05 per 1M tokens.
const DefaultInputPricePerMillion int64 = 50_000

// DefaultOutputPricePerMillion is the fallback output price for models without
// DB-configured pricing (micro-USD per 1M tokens). $0.20 per 1M tokens.
const DefaultOutputPricePerMillion int64 = 200_000

// Minimum charge per inference request in micro-USD ($0.0001).
const minimumChargeMicroUSD int64 = 100

// Platform fee percentage — Darkbloom retains 5% as a routing fee, provider receives 95%.
const platformFeePercent int64 = 5

// MinimumCharge returns the minimum charge per inference request in micro-USD.
func MinimumCharge() int64 {
	return minimumChargeMicroUSD
}

// InputPricePerMillion returns the fallback price in micro-USD for 1M input tokens.
// Callers should check the store for model-specific prices first.
func InputPricePerMillion(_ string) int64 {
	return DefaultInputPricePerMillion
}

// OutputPricePerMillion returns the fallback price in micro-USD for 1M output tokens.
// Callers should check the store for model-specific prices first.
func OutputPricePerMillion(_ string) int64 {
	return DefaultOutputPricePerMillion
}

// CalculateCost returns the total cost in micro-USD for a completed inference
// job. Both input (prompt) and output (completion) tokens are billed.
// A minimum charge of $0.0001 (100 micro-USD) applies to every request.
func CalculateCost(model string, promptTokens, completionTokens int) int64 {
	inputRate := InputPricePerMillion(model)
	outputRate := OutputPricePerMillion(model)

	inputCost := int64(promptTokens) * inputRate / 1_000_000
	outputCost := int64(completionTokens) * outputRate / 1_000_000
	cost := inputCost + outputCost

	if cost < minimumChargeMicroUSD {
		cost = minimumChargeMicroUSD
	}
	return cost
}

// CalculateCostWithOverrides is like CalculateCost but uses custom per-account
// prices if set, falling back to platform defaults. The per-request minimum
// charge is applied.
func CalculateCostWithOverrides(model string, promptTokens, completionTokens int, customInput, customOutput int64, hasCustom bool) int64 {
	return calculateCost(model, promptTokens, completionTokens, customInput, customOutput, hasCustom, true)
}

// CalculateCostWithOverridesNoMinimum is like CalculateCostWithOverrides but
// does NOT apply the per-request minimum charge. Used for service/wholesale
// channels (e.g. OpenRouter) whose advertised pricing is purely per-token
// (request price = 0), so the actual debit must match prompt*in + completion*out
// exactly rather than being floored.
func CalculateCostWithOverridesNoMinimum(model string, promptTokens, completionTokens int, customInput, customOutput int64, hasCustom bool) int64 {
	return calculateCost(model, promptTokens, completionTokens, customInput, customOutput, hasCustom, false)
}

func calculateCost(model string, promptTokens, completionTokens int, customInput, customOutput int64, hasCustom, applyMinimum bool) int64 {
	var inputRate, outputRate int64
	if hasCustom {
		inputRate = customInput
		outputRate = customOutput
	} else {
		inputRate = InputPricePerMillion(model)
		outputRate = OutputPricePerMillion(model)
	}

	inputCost := int64(promptTokens) * inputRate / 1_000_000
	outputCost := int64(completionTokens) * outputRate / 1_000_000
	cost := inputCost + outputCost

	if applyMinimum {
		if cost < minimumChargeMicroUSD {
			cost = minimumChargeMicroUSD
		}
	} else if cost == 0 && (promptTokens > 0 || completionTokens > 0) {
		// No per-request minimum (service/wholesale channel), but never give
		// nonzero usage away for free: integer micro-USD rounding can floor a
		// tiny request to 0, so charge at least 1 micro-USD.
		cost = 1
	}
	return cost
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
