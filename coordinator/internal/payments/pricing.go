package payments

// Pricing model for EigenInference.
//
// Prices are set at 50% of the cheapest major competitor for each model type.
// Users accept higher latency and lower reliability in exchange for the discount.
// Providers keep ~90%+ profit margin since marginal electricity on Apple Silicon
// is negligible ($0.001-0.05 per 1M tokens vs $0.075-1.04 revenue).
//
// All prices are in micro-USD per 1M tokens unless noted.
//
//   Model                              Input/1M    Output/1M    Competitor
//   ────────────────────────────────   ─────────   ──────────   ──────────
//   Qwen3.5 27B Claude Opus (dense)    $0.100      $0.780       OpenRouter $1.56
//   Trinity Mini (27B MoE, 3B active)  $0.023      $0.075       OpenRouter $0.15
//   Qwen3.5 122B (MoE, 10B active)     $0.130      $1.040       OpenRouter $2.08
//   MiniMax M2.5 (239B MoE, 11B act)   $0.060      $0.500       OpenRouter $1.00
//   Cohere Transcribe (2B STT)         $0.001/audio-minute      AssemblyAI $0.002
//   FLUX.2 Klein 4B (image)            $0.0015/image            Together $0.003
//   FLUX.2 Klein 9B (image)            $0.0025/image            fal.ai $0.005

// Default pricing for unknown models (micro-USD per 1M tokens).
// Falls back to a mid-range rate comparable to a 7B model.
const defaultInputPricePerMillion int64 = 50_000   // $0.05 per 1M input tokens
const defaultOutputPricePerMillion int64 = 200_000 // $0.20 per 1M output tokens

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
	// Text generation — 50% of OpenRouter rates
	"qwen3.5-27b-claude-opus-8bit":         {input: 100_000, output: 780_000},   // $0.10 / $0.78
	"mlx-community/Trinity-Mini-8bit":      {input: 23_000, output: 75_000},     // $0.023 / $0.075
	"mlx-community/Qwen3.5-122B-A10B-8bit": {input: 130_000, output: 1_040_000}, // $0.13 / $1.04
	"mlx-community/MiniMax-M2.5-8bit":      {input: 60_000, output: 500_000},    // $0.06 / $0.50
}

// transcriptionPricing stores per-audio-minute prices in micro-USD.
var transcriptionPricing = map[string]int64{
	"CohereLabs/cohere-transcribe-03-2026": 1_000, // $0.001 per audio-minute (50% of AssemblyAI Nano $0.002)
}

const defaultTranscriptionPricePerMinute int64 = 1_000

// imagePricing stores per-image prices in micro-USD.
var imagePricing = map[string]int64{
	"flux_2_klein_4b_q8p.ckpt": 1_500, // $0.0015 per image (50% of Together.ai $0.003)
	"flux_2_klein_9b_q8p.ckpt": 2_500, // $0.0025 per image (50% of fal.ai $0.005)
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

// DefaultTranscriptionPrices returns per-minute pricing for STT models.
func DefaultTranscriptionPrices() map[string]int64 {
	result := make(map[string]int64, len(transcriptionPricing))
	for model, price := range transcriptionPricing {
		result[model] = price
	}
	return result
}

// DefaultImagePrices returns per-image pricing for image models.
func DefaultImagePrices() map[string]int64 {
	result := make(map[string]int64, len(imagePricing))
	for model, price := range imagePricing {
		result[model] = price
	}
	return result
}

// ImagePricePerImage returns the per-image price in micro-USD for the given model.
func ImagePricePerImage(model string) int64 {
	if p, ok := imagePricing[model]; ok {
		return p
	}
	return 1_500 // default to cheapest model price
}

// TranscriptionPricePerMinute returns the per-audio-minute price in micro-USD.
func TranscriptionPricePerMinute(model string) int64 {
	if p, ok := transcriptionPricing[model]; ok {
		return p
	}
	return defaultTranscriptionPricePerMinute
}

// CalculateImageCost returns the total cost in micro-USD for an image generation
// job. Pricing is per-image based on the model's per-image price.
func CalculateImageCost(model string, width, height, count int) int64 {
	pricePerImage := ImagePricePerImage(model)

	totalCost := pricePerImage * int64(count)
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
