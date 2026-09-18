package trial

import (
	"fmt"
	"math"
	"math/bits"

	"github.com/eigeninference/d-inference/coordinator/payments"
)

// Rates uses the same units as model_prices: micro-USD per million tokens.
// Persist this value with a reservation so repricing cannot change settlement.
type Rates struct {
	InputMicroUSDPerMillion  int64
	OutputMicroUSDPerMillion int64
}

func (r Rates) Validate() error {
	if r.InputMicroUSDPerMillion <= 0 || r.OutputMicroUSDPerMillion <= 0 {
		return fmt.Errorf("trial input and output prices must both be positive")
	}
	return nil
}

// DeriveRates takes explicitly configured Qwen 3.8 27B rates. The caller must
// verify their model identity and provenance; fallback prices are not valid
// evidence. Reject sub-micro-USD results rather than round the promised ratio.
func DeriveRates(reference Rates) (Rates, error) {
	if err := reference.Validate(); err != nil {
		return Rates{}, err
	}
	if reference.InputMicroUSDPerMillion%10 != 0 || reference.OutputMicroUSDPerMillion%10 != 0 {
		return Rates{}, fmt.Errorf("one tenth of reference prices must be exactly representable in micro-USD")
	}
	return Rates{
		InputMicroUSDPerMillion:  reference.InputMicroUSDPerMillion / 10,
		OutputMicroUSDPerMillion: reference.OutputMicroUSDPerMillion / 10,
	}, nil
}

// Cost preserves paid inference's separate input/output truncation and minimum
// charge, including its minimum for zero-token completed requests. No consumer
// is charged this amount for a trial: it is the platform-funded service cost.
// Full-width multiplication prevents overflow before division.
func (r Rates) Cost(prompt, completion int64) (int64, error) {
	if err := r.Validate(); err != nil {
		return 0, err
	}
	if prompt < 0 || completion < 0 {
		return 0, fmt.Errorf("token usage cannot be negative")
	}
	input, err := tokenCost(prompt, r.InputMicroUSDPerMillion)
	if err != nil {
		return 0, err
	}
	output, err := tokenCost(completion, r.OutputMicroUSDPerMillion)
	if err != nil || output > math.MaxInt64-input {
		return 0, fmt.Errorf("trial cost exceeds micro-USD integer range")
	}
	return max(input+output, payments.MinimumCharge()), nil
}

func tokenCost(tokens, rate int64) (int64, error) {
	hi, lo := bits.Mul64(uint64(tokens), uint64(rate))
	if hi >= 1_000_000 {
		return 0, fmt.Errorf("trial cost exceeds micro-USD integer range")
	}
	quotient, _ := bits.Div64(hi, lo, 1_000_000)
	if quotient > math.MaxInt64 {
		return 0, fmt.Errorf("trial cost exceeds micro-USD integer range")
	}
	return int64(quotient), nil
}
