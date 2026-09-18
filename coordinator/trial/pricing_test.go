package trial

import (
	"math"
	"math/big"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
)

func TestDeriveRates(t *testing.T) {
	// Deliberately synthetic and different; not a claim about production prices.
	ref := Rates{InputMicroUSDPerMillion: 120_000, OutputMicroUSDPerMillion: 470_000}
	got, err := DeriveRates(ref)
	if err != nil || got != (Rates{12_000, 47_000}) {
		t.Fatalf("DeriveRates(%+v) = %+v, %v", ref, got, err)
	}
	ref.InputMicroUSDPerMillion = 999_000
	if got.InputMicroUSDPerMillion != 12_000 {
		t.Fatal("reference repricing changed frozen Bonsai rates")
	}
	for _, ref := range []Rates{{}, {0, 10}, {10, 0}, {-10, 10}, {10, -10}, {1, 10}, {10, 11}, {11, 10}, {math.MaxInt64, 10}} {
		if got, err := DeriveRates(ref); err == nil || got != (Rates{}) {
			t.Errorf("DeriveRates(%+v) should reject, got %+v, %v", ref, got, err)
		}
	}
	large := (int64(math.MaxInt64) / 10) * 10
	if got, err := DeriveRates(Rates{large, large}); err != nil || got.InputMicroUSDPerMillion != large/10 {
		t.Fatalf("large exactly representable rates rejected: %+v, %v", got, err)
	}
}

func TestCostMatchesPaidRoundingAndMinimum(t *testing.T) {
	rates := Rates{12_000, 47_000}
	for _, tokens := range [][2]int64{{0, 0}, {1, 0}, {0, 1}, {1, 1}, {1_000_000, 0}, {0, 1_000_000}, {234_567, 876_543}, {5_000_000, 0}} {
		got, err := rates.Cost(tokens[0], tokens[1])
		want := payments.CalculateCostWithOverrides("synthetic", int(tokens[0]), int(tokens[1]), rates.InputMicroUSDPerMillion, rates.OutputMicroUSDPerMillion, true)
		if err != nil || got != want {
			t.Errorf("Cost(%v) = %d, %v; paid cost = %d", tokens, got, err, want)
		}
	}
	// Flooring each side separately must not round their combined fraction up.
	got, err := (Rates{1_000_001, 1_000_001}).Cost(101, 899)
	if err != nil || got != 1000 {
		t.Fatalf("independent floor changed: %d, %v", got, err)
	}
}

func TestCostFullWidthArithmetic(t *testing.T) {
	// Intermediate multiplication overflows int64, but the divided cost fits.
	got, err := (Rates{1_000_000, 1_000_000}).Cost(math.MaxInt64, 0)
	if err != nil || got != math.MaxInt64 {
		t.Fatalf("representable full-width product: %d, %v", got, err)
	}
	for _, tc := range []struct {
		rates Rates
		in    int64
		out   int64
	}{
		{Rates{1, 1}, -1, 0},
		{Rates{1, 1}, 0, -1},
		{Rates{0, 1}, 10, 10},
		{Rates{1, -1}, 10, 10},
		{Rates{math.MaxInt64, math.MaxInt64}, math.MaxInt64, math.MaxInt64},
		{Rates{2_000_000, 1}, math.MaxInt64, 0},
		{Rates{1, 2_000_000}, 0, math.MaxInt64},
		{Rates{1_000_000, 1_000_000}, math.MaxInt64, 1},
	} {
		if _, err := tc.rates.Cost(tc.in, tc.out); err == nil {
			t.Errorf("Cost(%+v, %d, %d) accepted invalid or overflowed cost", tc.rates, tc.in, tc.out)
		}
	}
}

func FuzzCostAgainstArbitraryPrecision(f *testing.F) {
	f.Add(int64(12_000), int64(47_000), int64(234_567), int64(876_543))
	f.Add(int64(1_000_000), int64(1), int64(math.MaxInt64), int64(0))
	f.Add(int64(math.MaxInt64), int64(math.MaxInt64), int64(math.MaxInt64), int64(math.MaxInt64))
	f.Add(int64(10), int64(10), int64(-1), int64(0))
	f.Fuzz(func(t *testing.T, input, output, prompt, completion int64) {
		got, err := (Rates{input, output}).Cost(prompt, completion)
		if input <= 0 || output <= 0 || prompt < 0 || completion < 0 {
			if err == nil {
				t.Fatal("accepted invalid rates or usage")
			}
			return
		}
		million := big.NewInt(1_000_000)
		in := new(big.Int).Mul(big.NewInt(input), big.NewInt(prompt))
		out := new(big.Int).Mul(big.NewInt(output), big.NewInt(completion))
		want := new(big.Int).Add(in.Quo(in, million), out.Quo(out, million))
		if !want.IsInt64() {
			if err == nil {
				t.Fatal("accepted cost beyond int64")
			}
			return
		}
		if err != nil || got != max(want.Int64(), payments.MinimumCharge()) {
			t.Fatalf("got %d, %v; arbitrary precision cost = %s", got, err, want)
		}
	})
}
