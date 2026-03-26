package payments

import (
	"testing"
)

func TestOutputPriceKnownModels(t *testing.T) {
	tests := []struct {
		model string
		want  int64
	}{
		{"mlx-community/Qwen2.5-0.5B-Instruct-4bit", 10_000},
		{"mlx-community/Qwen2.5-3B-Instruct-4bit", 25_000},
		{"mlx-community/Qwen2.5-7B-Instruct-4bit", 50_000},
		{"mlx-community/Qwen3.5-9B-Instruct-4bit", 70_000},
		{"mlx-community/Qwen2.5-14B-Instruct-4bit", 100_000},
		{"mlx-community/Qwen2.5-32B-Instruct-4bit", 150_000},
		{"mlx-community/Qwen2.5-72B-Instruct-4bit", 200_000},
		{"mlx-community/Qwen3.5-122B-Instruct-4bit", 800_000},
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
		{"mlx-community/Qwen2.5-0.5B-Instruct-4bit", 5_000},
		{"mlx-community/Qwen2.5-7B-Instruct-4bit", 20_000},
		{"mlx-community/Qwen3.5-9B-Instruct-4bit", 25_000},
		{"mlx-community/Qwen2.5-72B-Instruct-4bit", 60_000},
		{"mlx-community/Qwen3.5-122B-Instruct-4bit", 130_000},
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
			name:             "1M output tokens at 7B rate, no input",
			model:            "mlx-community/Qwen2.5-7B-Instruct-4bit",
			promptTokens:     0,
			completionTokens: 1_000_000,
			want:             50_000, // $0.05 output only
		},
		{
			name:             "1M input + 1M output at 7B rate",
			model:            "mlx-community/Qwen2.5-7B-Instruct-4bit",
			promptTokens:     1_000_000,
			completionTokens: 1_000_000,
			want:             70_000, // $0.02 input + $0.05 output = $0.07
		},
		{
			name:             "only input tokens at 72B rate",
			model:            "mlx-community/Qwen2.5-72B-Instruct-4bit",
			promptTokens:     1_000_000,
			completionTokens: 0,
			want:             60_000, // $0.06 input, no output
		},
		{
			name:             "122B model 1M each",
			model:            "mlx-community/Qwen3.5-122B-Instruct-4bit",
			promptTokens:     1_000_000,
			completionTokens: 1_000_000,
			want:             930_000, // $0.13 input + $0.80 output = $0.93
		},
		{
			name:             "small request hits minimum",
			model:            "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
			promptTokens:     10,
			completionTokens: 10,
			want:             100, // minimum $0.0001
		},
		{
			name:             "zero tokens hits minimum",
			model:            "mlx-community/Qwen2.5-7B-Instruct-4bit",
			promptTokens:     0,
			completionTokens: 0,
			want:             100, // minimum
		},
		{
			name:             "small 0.5B model is cheapest",
			model:            "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
			promptTokens:     0,
			completionTokens: 1_000_000,
			want:             10_000, // $0.01
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
		{100_000, 5_000},      // 5% of $0.10
		{1_000_000, 50_000},   // 5% of $1.00
		{500_000, 25_000},     // 5% of $0.50
		{1_000, 50},           // 5% of $0.001
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
		{100_000, 95_000},     // 95% of $0.10
		{1_000_000, 950_000},  // 95% of $1.00
		{1_000, 950},          // 95% of $0.001
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

func TestBiggerModelsCostMore(t *testing.T) {
	small := OutputPricePerMillion("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
	medium := OutputPricePerMillion("mlx-community/Qwen2.5-7B-Instruct-4bit")
	large := OutputPricePerMillion("mlx-community/Qwen2.5-72B-Instruct-4bit")
	huge := OutputPricePerMillion("mlx-community/Qwen3.5-122B-Instruct-4bit")

	if small >= medium {
		t.Errorf("0.5B (%d) should be cheaper than 7B (%d)", small, medium)
	}
	if medium >= large {
		t.Errorf("7B (%d) should be cheaper than 72B (%d)", medium, large)
	}
	if large >= huge {
		t.Errorf("72B (%d) should be cheaper than 122B (%d)", large, huge)
	}
}

func TestAllModelPricesUndercutOpenRouter(t *testing.T) {
	// OpenRouter output prices (micro-USD per 1M tokens)
	openRouterOutput := map[string]int64{
		"mlx-community/Qwen2.5-0.5B-Instruct-4bit": 20_000,    // ~$0.02
		"mlx-community/Qwen2.5-7B-Instruct-4bit":   100_000,   // $0.10
		"mlx-community/Qwen3.5-9B-Instruct-4bit":   150_000,   // $0.15
		"mlx-community/Qwen2.5-72B-Instruct-4bit":  390_000,   // $0.39
		"mlx-community/Qwen3.5-122B-Instruct-4bit": 1_560_000, // $1.56
	}

	for model, orPrice := range openRouterOutput {
		ourPrice := OutputPricePerMillion(model)
		if ourPrice >= orPrice {
			t.Errorf("%s: our output price %d >= OpenRouter %d", model, ourPrice, orPrice)
		}
	}

	// OpenRouter input prices (micro-USD per 1M tokens)
	openRouterInput := map[string]int64{
		"mlx-community/Qwen2.5-7B-Instruct-4bit":   40_000,    // $0.04
		"mlx-community/Qwen3.5-9B-Instruct-4bit":   50_000,    // $0.05
		"mlx-community/Qwen2.5-72B-Instruct-4bit":  120_000,   // $0.12
		"mlx-community/Qwen3.5-122B-Instruct-4bit": 260_000,   // $0.26
	}

	for model, orPrice := range openRouterInput {
		ourPrice := InputPricePerMillion(model)
		if ourPrice >= orPrice {
			t.Errorf("%s: our input price %d >= OpenRouter %d", model, ourPrice, orPrice)
		}
	}
}
