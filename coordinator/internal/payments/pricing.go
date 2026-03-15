package payments

// Pricing model for DGInf inference.
//
// The pricing is intentionally simple for MVP: a flat rate per output token
// across all models, with a minimum charge per request. The platform takes
// a 10% fee and the provider receives the remaining 90%.
//
// This rate ($0.50 per 1M output tokens) is competitive with cloud pricing
// while providing meaningful revenue for GPU providers. Model-specific
// pricing can be added to the modelPricing map as the platform scales.

// Default pricing in micro-USD per million output tokens.
// Competitive with cloud pricing while rewarding local GPU providers.
const defaultPricePerMillionTokens int64 = 500_000 // $0.50 per 1M tokens

// Minimum charge per inference request in micro-USD ($0.001).
const minimumChargeMicroUSD int64 = 1_000

// Platform fee percentage (10% for MVP).
const platformFeePercent int64 = 10

// modelPricing maps model name patterns to per-million-token prices.
// This can be extended with model-specific pricing later.
var modelPricing = map[string]int64{
	// Defaults — all models use the same rate for MVP.
}

// PricePerMillionTokens returns the price in micro-USD for 1M output tokens
// of the given model. Returns the default rate if no model-specific price is set.
func PricePerMillionTokens(model string) int64 {
	if price, ok := modelPricing[model]; ok {
		return price
	}
	return defaultPricePerMillionTokens
}

// CalculateCost returns the total cost in micro-USD for a completed inference
// job. Output tokens are the primary cost driver. A minimum charge of $0.001
// (1,000 micro-USD) applies to every request.
func CalculateCost(model string, promptTokens, completionTokens int) int64 {
	outputRate := PricePerMillionTokens(model)

	// Cost = (completion_tokens * rate_per_million) / 1_000_000
	cost := int64(completionTokens) * outputRate / 1_000_000

	// Enforce minimum charge
	if cost < minimumChargeMicroUSD {
		cost = minimumChargeMicroUSD
	}
	return cost
}

// PlatformFee returns DGInf's cut of the total cost (10% for MVP).
func PlatformFee(totalCost int64) int64 {
	return totalCost * platformFeePercent / 100
}

// ProviderPayout returns the amount the provider receives after the platform
// fee is deducted.
func ProviderPayout(totalCost int64) int64 {
	return totalCost - PlatformFee(totalCost)
}
