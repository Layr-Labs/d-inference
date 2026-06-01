package payments

import "testing"

// TestUSDToMicroRounds pins the canonical rounding behavior. Several billing
// call sites previously truncated (int64(usd*1e6)); they now route through
// USDToMicro, which rounds. The 0.0000019 case is the one that distinguishes
// rounding (2) from the old truncation (1).
func TestUSDToMicroRounds(t *testing.T) {
	cases := []struct {
		usd  float64
		want int64
	}{
		{0, 0},
		{1, 1_000_000},
		{0.5, 500_000},
		{0.0000019, 2},  // rounds up; truncation would yield 1
		{0.00000142, 1}, // rounds down
		{12.34, 12_340_000},
	}
	for _, c := range cases {
		if got := USDToMicro(c.usd); got != c.want {
			t.Errorf("USDToMicro(%v) = %d, want %d", c.usd, got, c.want)
		}
	}
}

func TestMicroToUSD(t *testing.T) {
	if got := MicroToUSD(1_500_000); got != 1.5 {
		t.Errorf("MicroToUSD(1_500_000) = %v, want 1.5", got)
	}
	if got := MicroToUSD(0); got != 0 {
		t.Errorf("MicroToUSD(0) = %v, want 0", got)
	}
}

func TestFormatUSD(t *testing.T) {
	cases := []struct {
		micro    int64
		decimals int
		want     string
	}{
		{1_500_000, 2, "1.50"},
		{1_234_567, 6, "1.234567"},
		{50_000, 4, "0.0500"},
	}
	for _, c := range cases {
		if got := FormatUSD(c.micro, c.decimals); got != c.want {
			t.Errorf("FormatUSD(%d, %d) = %q, want %q", c.micro, c.decimals, got, c.want)
		}
	}
}

// TestCalculateCostDelegates pins that CalculateCost stays equivalent to the
// shared calculateCost (it now delegates instead of duplicating the math).
func TestCalculateCostDelegates(t *testing.T) {
	for _, c := range []struct{ prompt, completion int }{
		{0, 0}, {10, 20}, {1000, 2000}, {1, 0}, {0, 1},
	} {
		want := calculateCost("m", c.prompt, c.completion, 0, 0, false, true)
		if got := CalculateCost("m", c.prompt, c.completion); got != want {
			t.Errorf("CalculateCost(%d,%d) = %d, want %d", c.prompt, c.completion, got, want)
		}
	}
}
