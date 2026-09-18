package trial

import (
	"fmt"
	"math"
)

// ReservationTokens combines a caller-verified prompt upper bound and enforced
// output bound. Multiplicity reserves a full prompt per completion, which is
// conservative for backends that account the shared prompt only once. This
// function does not estimate template/tokenizer overhead; callers must bound
// that with model-specific evidence before enabling a campaign.
func ReservationTokens(promptBound, maxOutput, n int64) (int64, error) {
	if promptBound < 0 || maxOutput <= 0 || n <= 0 {
		return 0, fmt.Errorf("prompt bound must be nonnegative and output bound and multiplicity must be positive")
	}
	if promptBound > math.MaxInt64-maxOutput {
		return 0, fmt.Errorf("trial token reservation exceeds integer range")
	}
	perCompletion := promptBound + maxOutput
	if perCompletion > math.MaxInt64/n {
		return 0, fmt.Errorf("trial token reservation exceeds integer range")
	}
	return perCompletion * n, nil
}
