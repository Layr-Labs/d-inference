package payments

import "testing"

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

	// nil override → global default (5%).
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

func TestPlatformFeeBackwardCompatible(t *testing.T) {
	const total int64 = 2_000_000
	if PlatformFee(total) != PlatformFeeWithPercent(total, nil) {
		t.Error("PlatformFee must equal the nil-override variant")
	}
	if ProviderPayout(total) != ProviderPayoutWithPercent(total, nil) {
		t.Error("ProviderPayout must equal the nil-override variant")
	}
}
