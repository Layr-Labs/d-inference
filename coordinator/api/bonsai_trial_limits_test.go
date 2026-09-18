package api

import (
	"encoding/json"
	"math"
	"math/big"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
)

func TestBonsaiTrialOutputLimits(t *testing.T) {
	for _, parsed := range []map[string]any{
		{}, {"max_tokens": 1}, {"max_completion_tokens": int64(100)}, {"max_output_tokens": json.Number("8192")},
		{"max_tokens": float64(1024), "max_completion_tokens": 1024, "max_output_tokens": int64(1024), "n": 1},
		{"n": float64(1)},
	} {
		if err := validateTrialOutputLimits(parsed); err != nil {
			t.Errorf("valid limits %+v rejected: %v", parsed, err)
		}
	}
	for _, name := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens", "n"} {
		for _, value := range []any{nil, true, "100", 0, -1, int64(-1), 0.5, math.NaN(), math.Inf(1), math.Inf(-1), float64(1 << 54), json.Number("9223372036854775808"), json.Number("1.2"), json.Number("0")} {
			if err := validateTrialOutputLimits(map[string]any{name: value}); err == nil {
				t.Errorf("invalid %s=%v accepted", name, value)
			}
		}
	}
	for _, parsed := range []map[string]any{
		{"max_tokens": 10, "max_completion_tokens": 11},
		{"max_completion_tokens": 10, "max_output_tokens": 11},
		{"max_tokens": 10, "max_output_tokens": 11},
		{"n": 2}, {"n": int64(math.MaxInt64)},
	} {
		if err := validateTrialOutputLimits(parsed); err == nil {
			t.Errorf("conflicting or unsupported limits accepted: %+v", parsed)
		}
	}
}

func TestBonsaiTrialProviderPayoutOverflowSafe(t *testing.T) {
	for _, cost := range []int64{0, 1, 99, 100, 101, math.MaxInt64 / 2, math.MaxInt64} {
		for _, fee := range []int64{-100, 0, 1, 25, 99, 100, 101, math.MaxInt64} {
			pct := max(int64(0), min(int64(100), fee))
			feeBig := new(big.Int).Mul(big.NewInt(cost), big.NewInt(pct))
			feeBig.Quo(feeBig, big.NewInt(100))
			want := cost - feeBig.Int64()
			if got := trialProviderPayout(cost, &fee); got != want {
				t.Errorf("payout(%d, %d) = %d, want %d", cost, fee, got, want)
			}
		}
	}
	if got, want := trialProviderPayout(101, nil), payments.ProviderPayout(101); got != want {
		t.Fatalf("default fee changed: got %d want %d", got, want)
	}
}
