package inference_test

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
)

// TestShouldStopFailover_TimeoutCapCountsOnlySyntheticTimeouts pins the
// counting rule at the unit level: only the untyped 504 (the dispatch loop's
// synthetic first-chunk timeout discriminator) consumes the timeout allowance;
// a TYPED provider 504 (safety_deadline — a real provider terminal) keeps its
// existing fault-failover behavior and consumes nothing.
func TestShouldStopFailover_TimeoutCapCountsOnlySyntheticTimeouts(t *testing.T) {
	srv, _ := testServer(t)
	c := retry.New(retry.Config{Model: "cap-count-model", Observation: srv.observation})
	var terminal retry.TerminalEvidence

	// A typed provider 504 must not touch the timeout counter.
	d := retry.CoordinatorFailure("safety_deadline: safety ceiling expired", http.StatusGatewayTimeout)
	d.Message.TerminalCause = failure.TerminalCauseSafetyDeadline
	decision := c.Decide(d.Message, d.ProviderBudget)
	if decision.Stop {
		t.Fatal("typed provider 504 must keep the existing fault failover, not stop")
	}
	if decision.TimeoutRetries != 0 {
		t.Fatalf("typed 504 consumed the timeout allowance: %d", decision.TimeoutRetries)
	}

	// Synthetic timeouts stop at exactly maxFirstChunkTimeoutRetries.
	for i := 1; i < retry.TimeoutRetryLimit; i++ {
		d = retry.CoordinatorFailure("timeout waiting for first response", http.StatusGatewayTimeout)
		if c.Decide(d.Message, d.ProviderBudget).Stop {
			t.Fatalf("synthetic timeout %d stopped early (cap is %d)", i, retry.TimeoutRetryLimit)
		}
	}
	d = retry.CoordinatorFailure("timeout waiting for first response", http.StatusGatewayTimeout)
	if !c.Decide(d.Message, d.ProviderBudget).Stop {
		t.Fatalf("synthetic timeout %d must stop the ladder", retry.TimeoutRetryLimit)
	}

	// The exhausted ladder must reclassify the latched synthetic 504 to the
	// retryable 429 with the closed first_chunk_timeout reason.
	failure, sticky := terminal.Select(retry.NewTerminalFailure(d.Message, backend.Slot{}), false)
	code, reason, reclassified, dominance := retry.ResolveTerminal(failure, sticky, retry.TerminalPolicy{})
	if code != http.StatusTooManyRequests || reason != "first_chunk_timeout" || !reclassified {
		t.Fatalf("exhausted classification = (%d, %q, %v), want (429, first_chunk_timeout, true)", code, reason, reclassified)
	}
	if dominance != retry.Undecided {
		t.Fatalf("dominance = %d, want exhaustedUndecided (plain reclassified timeout)", dominance)
	}
}
