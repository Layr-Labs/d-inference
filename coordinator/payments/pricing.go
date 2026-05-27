package payments

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
// prices if set, falling back to platform defaults.
func CalculateCostWithOverrides(model string, promptTokens, completionTokens int, customInput, customOutput int64, hasCustom bool) int64 {
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

	if cost < minimumChargeMicroUSD {
		cost = minimumChargeMicroUSD
	}
	return cost
}

// PlatformFee returns Darkbloom's routing fee (5%).
func PlatformFee(totalCost int64) int64 {
	return totalCost * platformFeePercent / 100
}

// ProviderPayout returns the amount the provider receives (95%).
func ProviderPayout(totalCost int64) int64 {
	return totalCost - PlatformFee(totalCost)
}
