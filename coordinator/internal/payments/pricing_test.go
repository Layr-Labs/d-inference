package payments

import (
	"testing"
)

func TestOutputPriceKnownModels(t *testing.T) {
	tests := []struct {
		model string
		want  int64
	}{
		{"qwen3.5-27b-claude-opus-8bit", 780_000},
		{"mlx-community/Trinity-Mini-8bit", 75_000},
		{"mlx-community/Qwen3.5-122B-A10B-8bit", 1_040_000},
		{"mlx-community/MiniMax-M2.5-8bit", 500_000},
	}

	for _, tc := range tests {
		got := OutputPricePerMillion(tc.model)
		if got != tc.want {
			t.Errorf("OutputPricePerMillion(%q) = %d, want %d", tc.model, got, tc.want)
		}
	}
}

func TestInputPriceKnownModels(t *testing.T) {
	tests := []struct {
		model string
		want  int64
	}{
		{"qwen3.5-27b-claude-opus-8bit", 100_000},
		{"mlx-community/Trinity-Mini-8bit", 23_000},
		{"mlx-community/Qwen3.5-122B-A10B-8bit", 130_000},
		{"mlx-community/MiniMax-M2.5-8bit", 60_000},
	}

	for _, tc := range tests {
		got := InputPricePerMillion(tc.model)
		if got != tc.want {
			t.Errorf("InputPricePerMillion(%q) = %d, want %d", tc.model, got, tc.want)
		}
	}
}

func TestInputCheaperThanOutput(t *testing.T) {
	for model := range modelPricing {
		input := InputPricePerMillion(model)
		output := OutputPricePerMillion(model)
		if input >= output {
			t.Errorf("%s: input price %d >= output price %d", model, input, output)
		}
	}
}

func TestDefaultPricesForUnknownModel(t *testing.T) {
	input := InputPricePerMillion("unknown-model")
	output := OutputPricePerMillion("unknown-model")

	if input != defaultInputPricePerMillion {
		t.Errorf("default input = %d, want %d", input, defaultInputPricePerMillion)
	}
	if output != defaultOutputPricePerMillion {
		t.Errorf("default output = %d, want %d", output, defaultOutputPricePerMillion)
	}
}

func TestCalculateCost(t *testing.T) {
	tests := []struct {
		name             string
		model            string
		promptTokens     int
		completionTokens int
		want             int64
	}{
		{
			name:             "1M output tokens at Trinity Mini rate, no input",
			model:            "mlx-community/Trinity-Mini-8bit",
			promptTokens:     0,
			completionTokens: 1_000_000,
			want:             75_000, // $0.075 output only
		},
		{
			name:             "1M input + 1M output at Trinity Mini rate",
			model:            "mlx-community/Trinity-Mini-8bit",
			promptTokens:     1_000_000,
			completionTokens: 1_000_000,
			want:             98_000, // $0.023 input + $0.075 output = $0.098
		},
		{
			name:             "only input tokens at MiniMax rate",
			model:            "mlx-community/MiniMax-M2.5-8bit",
			promptTokens:     1_000_000,
			completionTokens: 0,
			want:             60_000, // $0.06 input, no output
		},
		{
			name:             "122B model 1M each",
			model:            "mlx-community/Qwen3.5-122B-A10B-8bit",
			promptTokens:     1_000_000,
			completionTokens: 1_000_000,
			want:             1_170_000, // $0.13 input + $1.04 output = $1.17
		},
		{
			name:             "small request hits minimum",
			model:            "mlx-community/Trinity-Mini-8bit",
			promptTokens:     10,
			completionTokens: 10,
			want:             100, // minimum $0.0001
		},
		{
			name:             "zero tokens hits minimum",
			model:            "mlx-community/Trinity-Mini-8bit",
			promptTokens:     0,
			completionTokens: 0,
			want:             100, // minimum
		},
		{
			name:             "Qwen3.5 27B Claude Opus 1M output",
			model:            "qwen3.5-27b-claude-opus-8bit",
			promptTokens:     0,
			completionTokens: 1_000_000,
			want:             780_000, // $0.78
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := CalculateCost(tc.model, tc.promptTokens, tc.completionTokens)
			if got != tc.want {
				t.Errorf("CalculateCost(%q, %d, %d) = %d, want %d",
					tc.model, tc.promptTokens, tc.completionTokens, got, tc.want)
			}
		})
	}
}

func TestPlatformFee(t *testing.T) {
	tests := []struct {
		totalCost int64
		wantFee   int64
	}{
		{100_000, 5_000},    // 5% of $0.10
		{1_000_000, 50_000}, // 5% of $1.00
		{500_000, 25_000},   // 5% of $0.50
		{1_000, 50},         // 5% of $0.001
		{0, 0},
	}

	for _, tc := range tests {
		got := PlatformFee(tc.totalCost)
		if got != tc.wantFee {
			t.Errorf("PlatformFee(%d) = %d, want %d", tc.totalCost, got, tc.wantFee)
		}
	}
}

func TestProviderPayout(t *testing.T) {
	tests := []struct {
		totalCost  int64
		wantPayout int64
	}{
		{100_000, 95_000},    // 95% of $0.10
		{1_000_000, 950_000}, // 95% of $1.00
		{1_000, 950},         // 95% of $0.001
		{0, 0},
	}

	for _, tc := range tests {
		got := ProviderPayout(tc.totalCost)
		if got != tc.wantPayout {
			t.Errorf("ProviderPayout(%d) = %d, want %d", tc.totalCost, got, tc.wantPayout)
		}
	}
}

func TestPlatformFeeAndProviderPayoutSumToTotal(t *testing.T) {
	totals := []int64{1_000, 10_000, 100_000, 500_000, 1_000_000, 10_000_000}
	for _, total := range totals {
		fee := PlatformFee(total)
		payout := ProviderPayout(total)
		if fee+payout != total {
			t.Errorf("PlatformFee(%d) + ProviderPayout(%d) = %d + %d = %d, want %d",
				total, total, fee, payout, fee+payout, total)
		}
	}
}

func TestAllModelPricesUndercutCompetitors(t *testing.T) {
	// Competitor output prices (micro-USD per 1M tokens)
	competitorOutput := map[string]int64{
		"qwen3.5-27b-claude-opus-8bit":         1_560_000, // OpenRouter $1.56
		"mlx-community/Trinity-Mini-8bit":      150_000,   // OpenRouter $0.15
		"mlx-community/Qwen3.5-122B-A10B-8bit": 2_080_000, // OpenRouter $2.08
		"mlx-community/MiniMax-M2.5-8bit":      1_000_000, // OpenRouter $1.00
	}

	for model, compPrice := range competitorOutput {
		ourPrice := OutputPricePerMillion(model)
		if ourPrice >= compPrice {
			t.Errorf("%s: our output price %d >= competitor %d", model, ourPrice, compPrice)
		}
	}

	// Competitor input prices (micro-USD per 1M tokens)
	competitorInput := map[string]int64{
		"qwen3.5-27b-claude-opus-8bit":         200_000, // OpenRouter $0.20
		"mlx-community/Trinity-Mini-8bit":      46_000,  // OpenRouter $0.046
		"mlx-community/Qwen3.5-122B-A10B-8bit": 260_000, // OpenRouter $0.26
		"mlx-community/MiniMax-M2.5-8bit":      120_000, // OpenRouter $0.12
	}

	for model, compPrice := range competitorInput {
		ourPrice := InputPricePerMillion(model)
		if ourPrice >= compPrice {
			t.Errorf("%s: our input price %d >= competitor %d", model, ourPrice, compPrice)
		}
	}
}

