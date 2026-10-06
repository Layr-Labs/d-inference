package inference_test

import (
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/rejection"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/retry"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestCapacityRejectionReasonThreadsIntoClassification pins the enriched-
// rejection funnel: the typed wire reason crosses the sanitizer as BOTH the
// preserved RejectionReason and a mapped structured error_reason, and the
// existing reason-first classifier (never a parallel one) produces the
// intended failover kind.
func TestCapacityRejectionReasonThreadsIntoClassification(t *testing.T) {
	tests := []struct {
		name       string
		rejection  protocol.CapacityRejectionReason
		wantReason string
		wantKind   rejection.Kind
	}{
		{"token_budget is node-transient", protocol.RejectionReasonTokenBudget, failure.ErrorReasonRequestExceedsNodeBudget, rejection.TransientCapacity},
		{"kv_headroom is node-transient", protocol.RejectionReasonKVHeadroom, failure.ErrorReasonRequestExceedsNode, rejection.TransientCapacity},
		{"memory_cap is node-transient", protocol.RejectionReasonMemoryCap, failure.ErrorReasonRequestExceedsNode, rejection.TransientCapacity},
		{"slot_state is busy-now", protocol.RejectionReasonSlotState, failure.ErrorReasonCapacityBusy, rejection.TransientCapacity},
		{"deadline is the neutral refusal", protocol.RejectionReasonDeadline, failure.ErrorReasonDeadlineUnreachable, rejection.DeadlineUnreachable},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			safe, _, _ := failure.SanitizeProviderError(&protocol.InferenceErrorMessage{
				Type:            protocol.TypeInferenceError,
				RequestID:       "r",
				StatusCode:      http.StatusServiceUnavailable,
				FailureCode:     protocol.FailureCodeCapacity,
				RejectionReason: tt.rejection,
			})
			if safe.RejectionReason != tt.rejection {
				t.Fatalf("RejectionReason=%q, want preserved %q", safe.RejectionReason, tt.rejection)
			}
			if safe.ErrorReason != tt.wantReason {
				t.Fatalf("ErrorReason=%q, want mapped %q", safe.ErrorReason, tt.wantReason)
			}
			if got := rejection.Classify(safe.ErrorReason, safe.Error, 0, 0, safe.RejectionReason); got != tt.wantKind {
				t.Fatalf("classifyRejection=%v, want %v", got, tt.wantKind)
			}
		})
	}

	// A provider-supplied structured reason always wins over the mapping.
	safe, _, _ := failure.SanitizeProviderError(&protocol.InferenceErrorMessage{
		Type:            protocol.TypeInferenceError,
		StatusCode:      http.StatusServiceUnavailable,
		FailureCode:     protocol.FailureCodeCapacity,
		ErrorReason:     failure.ErrorReasonRequestExceedsContext,
		RejectionReason: protocol.RejectionReasonTokenBudget,
	})
	if safe.ErrorReason != failure.ErrorReasonRequestExceedsContext {
		t.Fatalf("ErrorReason=%q, want the provider's own %q untouched", safe.ErrorReason, failure.ErrorReasonRequestExceedsContext)
	}
}

// TestSetLastInferenceErrorPrefersLiveBudgetAndKeepsFeasibleAfter pins the
// enriched-field capture: the rejection-time live budget replaces the stale
// heartbeat snapshot for the deterministic-vs-transient call, FeasibleAfterMS
// survives for the Retry-After surface, and a later coordinator-synthetic
// error clears both (no bleed-through).
func TestSetLastInferenceErrorPrefersLiveBudgetAndKeepsFeasibleAfter(t *testing.T) {
	srv := newTestServerForDispatch(t)
	var terminal retry.TerminalEvidence
	const modelMaxContext = 8192
	liveBudget := int64(4096)
	d := terminal.Observe(nil, "m", protocol.InferenceErrorMessage{
		Type:                 protocol.TypeInferenceError,
		StatusCode:           http.StatusServiceUnavailable,
		FailureCode:          protocol.FailureCodeCapacity,
		ErrorReason:          failure.ErrorReasonRequestExceedsBatchBudget,
		AvailableTokenBudget: &liveBudget,
		FeasibleAfterMS:      1500,
	}, modelMaxContext, backend.NewLatch(srv.registry))
	if d.ProviderBudget != 4096 {
		t.Fatalf("lastErrProviderBudget=%d, want the live 4096 (provider is nil: no heartbeat snapshot)", d.ProviderBudget)
	}
	if d.Message.FeasibleAfterMS != 1500 {
		t.Fatalf("lastErrFeasibleAfterMS=%d, want 1500", d.Message.FeasibleAfterMS)
	}
	// Live budget (4096) below the model context (8192): a batch-budget
	// reject from THIS pressured node is transient, not fleet-deterministic.
	if got := rejection.Classify(d.Message.ErrorReason, d.Message.Error, d.ProviderBudget, modelMaxContext, d.Message.RejectionReason); got != rejection.TransientCapacity {
		t.Fatalf("classifyRejection=%v, want rejectionTransientCapacity via the live budget", got)
	}
	d = retry.CoordinatorFailure("timeout waiting for first response", http.StatusGatewayTimeout)
	if d.Message.FeasibleAfterMS != 0 {
		t.Fatalf("lastErrFeasibleAfterMS=%d after synthetic error, want cleared", d.Message.FeasibleAfterMS)
	}
}

// TestSetLastInferenceErrorExplicitZeroBudgetStaysTransient pins the P1-4
// authority chain end to end: an enriched busy-slot rejection carrying an
// EXPLICIT zero live budget plus the typed token_budget reason crosses the
// sanitizer with both intact, and classification stays TRANSIENT — the typed
// reason is authoritative, so the stale heartbeat fallback (an unknown or
// at/above-context budget snapshot would otherwise read fleet-deterministic)
// can never stop failover for a shortage the live gate called momentary.
func TestSetLastInferenceErrorExplicitZeroBudgetStaysTransient(t *testing.T) {
	srv := newTestServerForDispatch(t)
	var terminal retry.TerminalEvidence
	const modelMaxContext = 8192
	liveBudget := int64(0)
	d := terminal.Observe(nil, "m", protocol.InferenceErrorMessage{
		Type:                 protocol.TypeInferenceError,
		StatusCode:           http.StatusServiceUnavailable,
		FailureCode:          protocol.FailureCodeCapacity,
		ErrorReason:          failure.ErrorReasonRequestExceedsBatchBudget,
		RejectionReason:      protocol.RejectionReasonTokenBudget,
		AvailableTokenBudget: &liveBudget,
	}, modelMaxContext, backend.NewLatch(srv.registry))
	if d.ProviderBudget != 0 {
		t.Fatalf("lastErrProviderBudget=%d, want the explicit live zero", d.ProviderBudget)
	}
	if d.Message.RejectionReason != protocol.RejectionReasonTokenBudget {
		t.Fatalf("lastErrRejectionReason=%q, want token_budget preserved through the sanitizer", d.Message.RejectionReason)
	}
	if got := rejection.Classify(d.Message.ErrorReason, d.Message.Error, d.ProviderBudget, modelMaxContext, d.Message.RejectionReason); got != rejection.TransientCapacity {
		t.Fatalf("classifyRejection=%v, want transient — typed token_budget is authoritative over the stale heartbeat fallback", got)
	}
	// Failover continues: the transient verdict consumes a capacity retry
	// instead of latching unservable on the first occurrence.
	c := retry.New(retry.Config{Model: "m", ModelContext: modelMaxContext, Observation: srv.observation})
	decision := c.Decide(d.Message, d.ProviderBudget)
	if decision.Stop {
		t.Fatal("first typed token_budget rejection must keep failing over")
	}
	if decision.UnservableReason != "" {
		t.Fatal("typed token_budget rejection must not latch deterministic-unservable")
	}
	// Legacy frame (nil budget, no typed reason): today's classification is
	// byte-identical — unknown budget ⇒ deterministic stop.
	srv2 := newTestServerForDispatch(t)
	var terminal2 retry.TerminalEvidence
	d2 := terminal2.Observe(nil, "m", protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		StatusCode:  http.StatusServiceUnavailable,
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: failure.ErrorReasonRequestExceedsBatchBudget,
	}, modelMaxContext, backend.NewLatch(srv2.registry))
	if got := rejection.Classify(d2.Message.ErrorReason, d2.Message.Error, d2.ProviderBudget, modelMaxContext, d2.Message.RejectionReason); got != rejection.DeterministicUnservable {
		t.Fatalf("legacy classifyRejection=%v, want unchanged deterministic", got)
	}
}
