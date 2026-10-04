package request_test

import (
	"fmt"
	"strings"
	"testing"

	jsonvalue "github.com/eigeninference/d-inference/coordinator/internal/inference/jsonvalue"
)

// Compare throughput and allocation growth without race/coverage instrumentation;
// a wall-clock cutoff in a unit test cannot establish linear parsing complexity.
func BenchmarkConstrainedExactNonnegativeIntAdversarialLiterals(b *testing.B) {
	for _, size := range []int{1_000, 64_000, 1_000_000, 4_000_000} {
		for _, prefix := range []string{"", "1."} {
			kind := "digits"
			if prefix != "" {
				kind = "fractional"
			}
			b.Run(fmt.Sprintf("%s/%d", kind, size), func(b *testing.B) {
				literal := prefix + strings.Repeat("9", size)
				b.SetBytes(int64(len(literal)))
				b.ReportAllocs()
				b.ResetTimer()
				for b.Loop() {
					if value, err := jsonvalue.ExactNonnegativeInt(literal); err == nil {
						b.Fatalf("oversized literal accepted: %d", value)
					}
				}
			})
		}
	}
}
