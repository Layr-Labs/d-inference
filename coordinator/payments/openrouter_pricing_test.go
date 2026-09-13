package payments

import (
	"strconv"
	"testing"
)

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

func TestCostNoMinimum(t *testing.T) {
	rates := DefaultRates()
	// A tiny request whose true token cost is below the 100 µUSD floor.
	// 10 prompt + 10 completion tokens at default rates is far under the floor.
	small := Usage{PromptTokens: 10, CompletionTokens: 10}
	withMin := rates.CostWithMinimum(small)
	noMin := rates.Cost(small)

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
	big := Usage{PromptTokens: 1_000_000, CompletionTokens: 1_000_000}
	if bigMin, bigNo := rates.CostWithMinimum(big), rates.Cost(big); bigMin != bigNo {
		t.Errorf("above-floor costs should match: withMin=%d noMin=%d", bigMin, bigNo)
	}

	// Nonzero usage must never be free: a 1-token request whose exact cost
	// rounds to 0 micro-USD is floored to 1 (no-minimum path).
	if tiny := rates.Cost(Usage{PromptTokens: 1}); tiny != 1 {
		t.Errorf("1-token no-minimum cost = %d, want 1 (no free inference)", tiny)
	}
	// A fully cached prompt at a zero cache-read rate is still nonzero usage.
	free := Rates{Input: DefaultInputPricePerMillion, Output: DefaultOutputPricePerMillion}
	if got := free.Cost(Usage{PromptTokens: 1_000, CachedTokens: 1_000}); got != 1 {
		t.Errorf("fully cached prompt at cache_read=0 cost = %d, want 1 (no free inference)", got)
	}
	// Genuinely zero usage stays zero.
	if z := rates.Cost(Usage{}); z != 0 {
		t.Errorf("zero-usage no-minimum cost = %d, want 0", z)
	}
}

// The OpenRouter feed advertises prompt, completion and input_cache_read as
// per-token USD strings; a service-account debit must equal what OpenRouter
// computes from those strings and the usage it receives. Both are derived from
// the same Rates, so this pins the round trip at micro-USD resolution.
func TestServiceCostMatchesAdvertisedPerTokenPrices(t *testing.T) {
	rates := Rates{Input: 300_000, Output: 1_200_000, CacheRead: 30_000}
	usage := Usage{PromptTokens: 40_000, CachedTokens: 32_000, CompletionTokens: 1_500}

	perToken := func(s string) float64 {
		v, err := strconv.ParseFloat(s, 64)
		if err != nil {
			t.Fatalf("parse %q: %v", s, err)
		}
		return v
	}
	advertised := float64(usage.PromptTokens-usage.CachedTokens)*perToken(FormatPerTokenUSD(rates.Input)) +
		float64(usage.CachedTokens)*perToken(FormatPerTokenUSD(rates.CacheRead)) +
		float64(usage.CompletionTokens)*perToken(FormatPerTokenUSD(rates.Output))
	// USD → micro-USD.
	wantMicro := int64(advertised*1_000_000 + 0.5)
	if got := rates.Cost(usage); got != wantMicro {
		t.Fatalf("service cost = %d µUSD, advertised per-token math = %d µUSD", got, wantMicro)
	}
}

func TestPlatformFeeBackwardCompatible(t *testing.T) {
	const total int64 = 2_000_000
	if PlatformFee(total) != PlatformFeeWithPercent(total, nil) {
		t.Error("PlatformFee must equal the nil-override variant")
	}
	if ProviderPayout(total) != ProviderPayoutWithPercent(total, nil) {
		t.Error("ProviderPayout must equal the nil-override variant")
	}
}
