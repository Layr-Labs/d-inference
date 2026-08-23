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

func TestFormatPerTokenUSD(t *testing.T) {
	cases := []struct {
		name               string
		microUSDPerMillion int64
		want               string
	}{
		{"zero", 0, "0"},
		{"default_input_0.05_per_1M", DefaultInputPricePerMillion, "0.00000005"},
		{"default_output_0.20_per_1M", DefaultOutputPricePerMillion, "0.0000002"},
		{"eight_dollars_per_1M", 8_000_000, "0.000008"},
		{"one_micro_unit", 1, "0.000000000001"},
		{"ten_dollars_per_1M", 10_000_000, "0.00001"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := FormatPerTokenUSD(tc.microUSDPerMillion); got != tc.want {
				t.Errorf("FormatPerTokenUSD(%d) = %q, want %q", tc.microUSDPerMillion, got, tc.want)
			}
		})
	}
}

func TestPlatformFeeWithPercent(t *testing.T) {
	const total int64 = 1_000_000

	// nil override → global default fee.
	if got := PlatformFeeWithPercent(total, nil); got != total*DefaultPlatformFeePercent/100 {
		t.Errorf("default fee = %d, want %d", got, total*DefaultPlatformFeePercent/100)
	}

	// 0% override → no fee, provider gets 100%.
	zero := int64(0)
	if got := PlatformFeeWithPercent(total, &zero); got != 0 {
		t.Errorf("0%% fee = %d, want 0", got)
	}
	if got := ProviderPayoutWithPercent(total, &zero); got != total {
		t.Errorf("0%% payout = %d, want %d (full amount)", got, total)
	}

	// Explicit 10% override.
	ten := int64(10)
	if got := PlatformFeeWithPercent(total, &ten); got != 100_000 {
		t.Errorf("10%% fee = %d, want 100000", got)
	}

	// Out-of-range overrides are clamped to [0,100].
	neg := int64(-5)
	if got := PlatformFeeWithPercent(total, &neg); got != 0 {
		t.Errorf("negative fee clamped = %d, want 0", got)
	}
	big := int64(150)
	if got := PlatformFeeWithPercent(total, &big); got != total {
		t.Errorf("over-100 fee clamped = %d, want %d", got, total)
	}
}

func TestCalculateCostNoMinimum(t *testing.T) {
	const model = "m"
	// A tiny request whose true token cost is below the 100 µUSD floor.
	// 10 prompt + 10 completion tokens at default rates is far under the floor.
	withMin := CalculateCostWithOverrides(model, 10, 10, 0, 0, false)
	noMin := CalculateCostWithOverridesNoMinimum(model, 10, 10, 0, 0, false)

	if withMin != MinimumCharge() {
		t.Errorf("with-minimum cost = %d, want floor %d", withMin, MinimumCharge())
	}
	if noMin >= MinimumCharge() {
		t.Errorf("no-minimum cost = %d, should be below the floor %d", noMin, MinimumCharge())
	}
	// No-minimum must equal the exact per-token math (no floor).
	want := int64(10)*DefaultInputPricePerMillion/1_000_000 + int64(10)*DefaultOutputPricePerMillion/1_000_000
	if noMin != want {
		t.Errorf("no-minimum cost = %d, want exact %d", noMin, want)
	}

	// For a large request above the floor, both variants agree.
	bigMin := CalculateCostWithOverrides(model, 1_000_000, 1_000_000, 0, 0, false)
	bigNo := CalculateCostWithOverridesNoMinimum(model, 1_000_000, 1_000_000, 0, 0, false)
	if bigMin != bigNo {
		t.Errorf("above-floor costs should match: withMin=%d noMin=%d", bigMin, bigNo)
	}

	// Nonzero usage must never be free: a 1-token request whose exact cost
	// rounds to 0 micro-USD is floored to 1 (no-minimum path).
	tiny := CalculateCostWithOverridesNoMinimum(model, 1, 0, 0, 0, false)
	if tiny != 1 {
		t.Errorf("1-token no-minimum cost = %d, want 1 (no free inference)", tiny)
	}
	// Genuinely zero usage stays zero.
	if z := CalculateCostWithOverridesNoMinimum(model, 0, 0, 0, 0, false); z != 0 {
		t.Errorf("zero-usage no-minimum cost = %d, want 0", z)
	}
}
