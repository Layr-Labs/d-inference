package payments

import (
	"testing"
)

func TestPricePerMillionTokensDefault(t *testing.T) {
	// Default: $0.50 per million tokens = 500,000 micro-USD.
	price := PricePerMillionTokens("unknown-model")
	if price != 500_000 {
		t.Errorf("default price = %d, want 500_000", price)
	}
}

func TestPricePerMillionTokensKnownModel(t *testing.T) {
	// For now all models use the same rate, but the function should work.
	price := PricePerMillionTokens("qwen3.5-9b")
	if price != 500_000 {
		t.Errorf("price = %d, want 500_000", price)
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
			name:             "1M output tokens at default rate",
			model:            "qwen3.5-9b",
			promptTokens:     100,
			completionTokens: 1_000_000,
			want:             500_000, // $0.50
		},
		{
			name:             "500K output tokens",
			model:            "qwen3.5-9b",
			promptTokens:     100,
			completionTokens: 500_000,
			want:             250_000, // $0.25
		},
		{
			name:             "100 output tokens hits minimum charge",
			model:            "qwen3.5-9b",
			promptTokens:     10,
			completionTokens: 100,
			want:             1_000, // minimum $0.001
		},
		{
			name:             "zero completion tokens hits minimum",
			model:            "qwen3.5-9b",
			promptTokens:     100,
			completionTokens: 0,
			want:             1_000, // minimum charge
		},
		{
			name:             "1 completion token hits minimum",
			model:            "test",
			promptTokens:     50,
			completionTokens: 1,
			want:             1_000, // minimum charge (1 * 500_000 / 1_000_000 = 0)
		},
		{
			name:             "2000 completion tokens exact calculation",
			model:            "test",
			promptTokens:     50,
			completionTokens: 2000,
			want:             1_000, // 2000 * 500_000 / 1_000_000 = 1000
		},
		{
			name:             "10000 completion tokens",
			model:            "test",
			promptTokens:     50,
			completionTokens: 10_000,
			want:             5_000, // 10000 * 500_000 / 1_000_000 = 5000
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
		{100_000, 10_000},     // 10% of $0.10 = $0.01
		{1_000_000, 100_000},  // 10% of $1.00 = $0.10
		{500_000, 50_000},     // 10% of $0.50 = $0.05
		{1_000, 100},          // 10% of $0.001 = $0.0001
		{0, 0},                // 10% of $0 = $0
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
		{100_000, 90_000},     // 90% of $0.10 = $0.09
		{1_000_000, 900_000},  // 90% of $1.00 = $0.90
		{1_000, 900},          // 90% of $0.001 = $0.0009
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
