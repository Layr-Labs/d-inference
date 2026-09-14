package dispatch

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
)

// TestShouldStopFailover_TimeoutCapCountsOnlySyntheticTimeouts pins the
// counting rule at the unit level: only the untyped 504 (the dispatch loop's
// synthetic first-chunk timeout discriminator) consumes the timeout allowance;
// a TYPED provider 504 (safety_deadline — a real provider terminal) keeps its
// existing fault-failover behavior and consumes nothing.
func TestShouldStopFailover_TimeoutCapCountsOnlySyntheticTimeouts(t *testing.T) {
	srv := newTestController(t)
	d := &execution{
		s:                srv,
		model:            "cap-count-model",
		excludeProviders: map[string]struct{}{},
	}

	// A typed provider 504 must not touch the timeout counter.
	d.setLastError("safety_deadline: safety ceiling expired", http.StatusGatewayTimeout)
	d.lastErrTerminalCause = attempt.TerminalCauseSafetyDeadline
	if d.shouldStopFailover() {
		t.Fatal("typed provider 504 must keep the existing fault failover, not stop")
	}
	if d.firstChunkTimeoutRetries != 0 {
		t.Fatalf("typed 504 consumed the timeout allowance: %d", d.firstChunkTimeoutRetries)
	}

	// Synthetic timeouts stop at exactly maxFirstChunkTimeoutRetries.
	for i := 1; i < maxFirstChunkTimeoutRetries; i++ {
		d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
		if d.shouldStopFailover() {
			t.Fatalf("synthetic timeout %d stopped early (cap is %d)", i, maxFirstChunkTimeoutRetries)
		}
	}
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	if !d.shouldStopFailover() {
		t.Fatalf("synthetic timeout %d must stop the ladder", maxFirstChunkTimeoutRetries)
	}

	if d.firstChunkTimeoutRetries != maxFirstChunkTimeoutRetries {
		t.Errorf("firstChunkTimeoutRetries = %d, want %d", d.firstChunkTimeoutRetries, maxFirstChunkTimeoutRetries)
	}

	// The exhausted ladder must reclassify the latched synthetic 504 to the
	// retryable 429 with the closed first_chunk_timeout reason.
	failure, sticky := d.terminalFailureForExhaustion()
	code, reason, reclassified, dominance := d.resolveDominantExhaustedStatus(failure, sticky)
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("exhausted classification = (%d, %q, %v), want (429, first_chunk_timeout, true)", code, reason, reclassified)
	}
	if dominance != exhaustedUndecided {
		t.Fatalf("dominance = %d, want exhaustedUndecided (plain reclassified timeout)", dominance)
	}
}
