package rewardeligibility_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/payments/rewardeligibility"
)

func TestOSVersionEligibleRequiresCompleteNumericVersion(t *testing.T) {
	for _, tc := range []struct {
		version string
		want    bool
	}{
		{"27", true}, {"27.0", true}, {"27.0.1", true}, {"28.4.9", true},
		{"26.9.9", false}, {"", false}, {"27 beta", false}, {"27.0.1.2", false},
		{"27.", false}, {".27", false}, {"27..1", false}, {"27.-1", false},
		{"+27", false}, {" 27", false}, {"27 ", false}, {"２７", false},
		{"18446744073709551616", false}, {"27.18446744073709551616", false},
	} {
		t.Run(tc.version, func(t *testing.T) {
			if got := rewardeligibility.OSVersionEligible(tc.version); got != tc.want {
				t.Fatalf("OSVersionEligible(%q) = %v, want %v", tc.version, got, tc.want)
			}
		})
	}
}
