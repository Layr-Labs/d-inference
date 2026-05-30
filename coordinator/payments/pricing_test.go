package payments

import (
	"testing"
)

func TestFallbackPricesForAnyModel(t *testing.T) {
	// Without DB-configured prices, all models get the fallback defaults.
	models := []string{
		"gpt-oss-20b",
		"gemma-4-26b",
		"qwen3.5-27b-claude-opus-8bit",
		"mlx-community/Trinity-Mini-8bit",
		"totally-unknown-model",
	}

	for _, model := range models {
		input := InputPricePerMillion(model)
		output := OutputPricePerMillion(model)

		if input != DefaultInputPricePerMillion {
			t.Errorf("InputPricePerMillion(%q) = %d, want fallback %d", model, input, DefaultInputPricePerMillion)
		}
		if output != DefaultOutputPricePerMillion {
			t.Errorf("OutputPricePerMillion(%q) = %d, want fallback %d", model, output, DefaultOutputPricePerMillion)
		}
	}
}

func TestCalculateCost(t *testing.T) {
	// All models use fallback pricing ($0.05 input, $0.20 output per 1M tokens).
	tests := []struct {
		name             string
		model            string
		promptTokens     int
		completionTokens int
		want             int64
	}{
		{
			name:             "1M output tokens at fallback rate",
			model:            "any-model",
			promptTokens:     0,
			completionTokens: 1_000_000,
			want:             200_000, // $0.20 output
		},
		{
			name:             "1M input + 1M output at fallback rate",
			model:            "any-model",
			promptTokens:     1_000_000,
			completionTokens: 1_000_000,
			want:             250_000, // $0.05 input + $0.20 output = $0.25
		},
		{
			name:             "only input tokens at fallback rate",
			model:            "any-model",
			promptTokens:     1_000_000,
			completionTokens: 0,
			want:             50_000, // $0.05 input
		},
		{
			name:             "small request hits minimum",
			model:            "any-model",
			promptTokens:     10,
			completionTokens: 10,
			want:             100, // minimum $0.0001
		},
		{
			name:             "zero tokens hits minimum",
			model:            "any-model",
			promptTokens:     0,
			completionTokens: 0,
			want:             100, // minimum
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

func TestCalculateCostWithOverrides(t *testing.T) {
	tests := []struct {
		name             string
		customInput      int64
		customOutput     int64
		hasCustom        bool
		promptTokens     int
		completionTokens int
		want             int64
	}{
		{
			name:             "custom prices override fallback",
			customInput:      15_000, // $0.015
			customOutput:     70_000, // $0.070
			hasCustom:        true,
			promptTokens:     1_000_000,
			completionTokens: 1_000_000,
			want:             85_000, // $0.015 + $0.070 = $0.085
		},
		{
			name:             "no custom falls back to defaults",
			hasCustom:        false,
			promptTokens:     1_000_000,
			completionTokens: 1_000_000,
			want:             250_000, // $0.05 + $0.20 = $0.25
		},
		{
			name:             "custom prices with minimum charge",
			customInput:      1_000,
			customOutput:     1_000,
			hasCustom:        true,
			promptTokens:     10,
			completionTokens: 10,
			want:             100, // minimum
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := CalculateCostWithOverrides("test-model", tc.promptTokens, tc.completionTokens,
				tc.customInput, tc.customOutput, tc.hasCustom)
			if got != tc.want {
				t.Errorf("CalculateCostWithOverrides = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestPlatformFee(t *testing.T) {
	tests := []struct {
		totalCost int64
		wantFee   int64
	}{
		// Default platform fee is 0% during the public alpha.
		{100_000, 0},
		{1_000_000, 0},
		{500_000, 0},
		{1_000, 0},
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
		// Providers keep 100% during the public alpha (0% default fee).
		{100_000, 100_000},
		{1_000_000, 1_000_000},
		{1_000, 1_000},
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
