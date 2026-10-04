package inference_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
	"testing"
)

// TestExhaustionAttemptCountPrefersProviderDispatches pins the Phase-3
// counting rule: client-visible exhaustion messages report frames actually
// handed to providers, falling back to the legacy loop count only when
// nothing ever dispatched.
func TestExhaustionAttemptCountPrefersProviderDispatches(t *testing.T) {
	d := &providerwire.Accounting{}
	if got := d.ExhaustionCount(7); got != 8 {
		t.Fatalf("no dispatches: count=%d, want legacy attempt+1=8", got)
	}
	d.Commit()
	d.Commit()
	d.Commit()
	if got := d.ExhaustionCount(7); got != 3 {
		t.Fatalf("count=%d, want 3 actual dispatches (not loop attempts)", got)
	}
}
