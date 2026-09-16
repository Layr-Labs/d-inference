package ingress

import (
	"math"
	"testing"
)

func TestRequestedOutputTokenEstimateRejectsOverflow(t *testing.T) {
	for _, field := range []string{"max_tokens", "max_completion_tokens", "max_output_tokens"} {
		t.Run(field, func(t *testing.T) {
			for _, tc := range []struct {
				maxTokens, copies, want int
				valid                   bool
			}{
				{7, 3, 21, true},
				{math.MaxInt / 2, 2, math.MaxInt - 1, true},
				{math.MaxInt/2 + 1, 2, 0, false},
				{4, math.MaxInt/2 + 2, 0, false},
				{math.MaxInt, 1, math.MaxInt, true},
			} {
				parsed := map[string]any{field: tc.maxTokens, "n": tc.copies}
				if got, valid := estimateRequestedMaxTokens(parsed); got != tc.want || valid != tc.valid {
					t.Errorf("%d tokens across %d choices = (%d, %t), want (%d, %t)", tc.maxTokens, tc.copies, got, valid, tc.want, tc.valid)
				}
			}
		})
	}
	if got, valid := estimateRequestedMaxTokens(map[string]any{"n": math.MaxInt}); valid || got != 0 {
		t.Errorf("default-token overflow = (%d, %t), want (0, false)", got, valid)
	}
	if got, valid := estimateRequestedMaxTokens(nil); !valid || got != 256 {
		t.Errorf("default-token estimate = (%d, %t), want (256, true)", got, valid)
	}
}
