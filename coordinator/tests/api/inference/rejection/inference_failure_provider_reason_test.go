package rejection_test

import (
	"testing"

	rejection "github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
)

// C3: classifyRejection trusts the P1 structured provider reason over the
// stale-snapshot heuristic; old providers (reason=="") fall through unchanged.
func TestClassifyRejection_P1StructuredReason(t *testing.T) {
	if got := rejection.Classify("request_exceeds_context", "", 0, 0, ""); got != rejection.DeterministicUnservable {
		t.Errorf("request_exceeds_context = %v, want deterministic", got)
	}
	if got := rejection.Classify("request_exceeds_node", "", 0, 0, ""); got != rejection.TransientCapacity {
		t.Errorf("request_exceeds_node = %v, want transient", got)
	}
	if got := rejection.Classify("capacity_busy", "", 0, 0, ""); got != rejection.TransientCapacity {
		t.Errorf("capacity_busy = %v, want transient", got)
	}
	// Old provider (no structured reason, non-capacity string) → unchanged fallback.
	if got := rejection.Classify("", "invalid tool payload", 0, 0, ""); got != rejection.NotCapacity {
		t.Errorf("legacy non-capacity = %v, want notCapacity", got)
	}
}

// P1 cross-component contract: the provider's new context-overflow message
// (emitted when prompt > model context) must classify as fleet-wide deterministic
// so the coordinator stops on the first attempt; the node-pressured batch-budget
// message (budget < context) must stay transient so it fails over to a bigger box.
func TestClassifyRejection_P1ContextOverflowMessage(t *testing.T) {
	ctxMsg := "token_budget_exhausted: request exceeds model context window (200000 prompt tokens > 131072 context)"
	if got := rejection.Classify("", ctxMsg, 0, 131072, ""); got != rejection.DeterministicUnservable {
		t.Errorf("context-overflow message must be deterministic; got %v", got)
	}
	nodeMsg := "token_budget_exhausted: request exceeds batch token budget"
	if got := rejection.Classify("", nodeMsg, 40000, 131072, ""); got != rejection.TransientCapacity {
		t.Errorf("pressured batch-budget (budget<context) must be transient; got %v", got)
	}
}
