package payments

// Pricing model for DGInf inference.
//
// Per-model pricing undercuts OpenRouter by ~50%. Since providers donate
// idle Apple Silicon GPU time with zero infrastructure cost, we can price
// aggressively while keeping a 5% routing fee.
//
// All prices are in micro-USD per 1M tokens.
// Both input (prompt) and output (completion) tokens are billed separately.
// Input tokens are cheaper than output — they only require prefill compute,
// while output tokens require sequential decoding.
//
//   Model                  OpenRouter (in/out)      DGInf (in/out)       Provider (95%)
//   ─────────────────────  ───────────────────      ──────────────       ──────────────
//   Qwen2.5-0.5B           $0.01 / $0.02           $0.005 / $0.01      $0.00475 / $0.0095
//   Qwen2.5-1.5B           $0.015 / $0.03          $0.007 / $0.015     $0.00665 / $0.01425
//   Qwen2.5-3B             $0.025 / $0.05          $0.012 / $0.025     $0.0114  / $0.02375
//   Qwen3.5-4B             $0.04 / $0.08           $0.02 / $0.04       $0.019   / $0.038
//   Qwen2.5-7B             $0.04 / $0.10           $0.02 / $0.05       $0.019   / $0.0475
//   Qwen3.5-9B             $0.05 / $0.15           $0.025 / $0.07      $0.02375 / $0.0665
//   Qwen2.5-14B            $0.08 / $0.20           $0.04 / $0.10       $0.038   / $0.095
//   Qwen2.5-32B            $0.12 / $0.30           $0.06 / $0.15       $0.057   / $0.1425
//   Qwen2.5-72B            $0.12 / $0.39           $0.06 / $0.20       $0.057   / $0.190
//   Qwen3.5-122B           $0.26 / $1.56           $0.13 / $0.80       $0.1235  / $0.760

// Default pricing for unknown models (micro-USD per 1M tokens).
// Falls back to a mid-range rate comparable to a 7B model.
const defaultInputPricePerMillion int64 = 20_000  // $0.02 per 1M input tokens
const defaultOutputPricePerMillion int64 = 50_000 // $0.05 per 1M output tokens

// Minimum charge per inference request in micro-USD ($0.0001).
const minimumChargeMicroUSD int64 = 100

// Platform fee percentage — DGInf retains 5% as a routing fee, provider receives 95%.
const platformFeePercent int64 = 5

// modelPricing stores input and output prices per model (micro-USD per 1M tokens).
type modelPrice struct {
	input  int64
	output int64
}

var modelPricing = map[string]modelPrice{
	// Qwen 2.5 family
	"mlx-community/Qwen2.5-0.5B-Instruct-4bit": {input: 5_000, output: 10_000},     // $0.005 / $0.01
	"mlx-community/Qwen2.5-1.5B-Instruct-4bit": {input: 7_000, output: 15_000},     // $0.007 / $0.015
	"mlx-community/Qwen2.5-3B-Instruct-4bit":   {input: 12_000, output: 25_000},    // $0.012 / $0.025
	"mlx-community/Qwen2.5-7B-Instruct-4bit":   {input: 20_000, output: 50_000},    // $0.02  / $0.05
	"mlx-community/Qwen2.5-14B-Instruct-4bit":  {input: 40_000, output: 100_000},   // $0.04  / $0.10
	"mlx-community/Qwen2.5-32B-Instruct-4bit":  {input: 60_000, output: 150_000},   // $0.06  / $0.15
	"mlx-community/Qwen2.5-72B-Instruct-4bit":  {input: 60_000, output: 200_000},   // $0.06  / $0.20

	// Qwen 3.5 family
	"mlx-community/Qwen3.5-4B-4bit":            {input: 20_000, output: 40_000},    // $0.02  / $0.04
	"mlx-community/Qwen3.5-9B-Instruct-4bit":   {input: 25_000, output: 70_000},    // $0.025 / $0.07
	"mlx-community/Qwen3.5-122B-Instruct-4bit": {input: 130_000, output: 800_000},  // $0.13  / $0.80
}

// InputPricePerMillion returns the price in micro-USD for 1M input tokens.
func InputPricePerMillion(model string) int64 {
	if p, ok := modelPricing[model]; ok {
		return p.input
	}
	return defaultInputPricePerMillion
}

// OutputPricePerMillion returns the price in micro-USD for 1M output tokens.
func OutputPricePerMillion(model string) int64 {
	if p, ok := modelPricing[model]; ok {
		return p.output
	}
	return defaultOutputPricePerMillion
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

// DefaultPrices returns the platform default pricing table.
func DefaultPrices() map[string][2]int64 {
	result := make(map[string][2]int64, len(modelPricing))
	for model, price := range modelPricing {
		result[model] = [2]int64{price.input, price.output}
	}
	return result
}

// CalculateImageCost returns the total cost in micro-USD for an image generation
// job. Pricing is per-image, scaled by resolution relative to 1024x1024 base.
// Base price: $0.002 per 1024x1024 image (2000 micro-USD).
func CalculateImageCost(model string, width, height, count int) int64 {
	const basePriceMicroUSD int64 = 2_000 // $0.002 per image at 1024x1024
	const basePixels int64 = 1024 * 1024

	pixels := int64(width) * int64(height)
	// Scale cost proportionally to pixel count (minimum 1x)
	scaledPrice := basePriceMicroUSD * pixels / basePixels
	if scaledPrice < basePriceMicroUSD/2 {
		scaledPrice = basePriceMicroUSD / 2 // minimum half-price for small images
	}

	totalCost := scaledPrice * int64(count)
	if totalCost < minimumChargeMicroUSD {
		totalCost = minimumChargeMicroUSD
	}
	return totalCost
}

// PlatformFee returns DGInf's routing fee (5%).
func PlatformFee(totalCost int64) int64 {
	return totalCost * platformFeePercent / 100
}

// ProviderPayout returns the amount the provider receives (95%).
func ProviderPayout(totalCost int64) int64 {
	return totalCost - PlatformFee(totalCost)
}
