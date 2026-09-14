package dispatch

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// TestLatchDeterministicLoser_Latches (DAR-347 #2): a deterministic-unservable
// rejection from a speculative race loser sets d.unservable even though the loser's
// error is never written to d.lastErr (the surviving racer owns that).
func TestLatchDeterministicLoser_Latches(t *testing.T) {
	d := &execution{s: newTestController(t), model: "m"}
	// Unknown budget + unknown context → the bounded batch-budget reason is deterministic.
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: attempt.ErrorReasonRequestExceedsBatchBudget,
	})
	if !d.unservable || d.unservableReason != rejectionReasonOversized {
		t.Fatalf("deterministic loser must latch unservable; got unservable=%v reason=%q", d.unservable, d.unservableReason)
	}
}

// TestLatchDeterministicLoser_IgnoresTransient (DAR-347 #2): a transient-capacity
// loser must NOT latch — failover to a healthier provider must still happen.
func TestLatchDeterministicLoser_IgnoresTransient(t *testing.T) {
	d := &execution{s: newTestController(t), model: "m"}
	d.latchDeterministicLoser(nil, protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: attempt.ErrorReasonQueueFull,
	})
	if d.unservable {
		t.Fatalf("a transient loser must NOT latch unservable (it would block legitimate failover)")
	}
}

// TestLatchDeterministicLoser_PressuredBatchBudgetNotLatched (DAR-347 #1 ∩ #2):
// the loser latch is budget-aware. A memory-pressured loser's "batch token budget"
// (reported budget below the model context) must NOT latch, so the race can still
// fail over to a healthier provider.
func TestLatchDeterministicLoser_PressuredBatchBudgetNotLatched(t *testing.T) {
	p := &registry.Provider{BackendCapacity: &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "running", ActiveTokenBudgetMax: 50_000}},
	}}
	d := &execution{s: newTestController(t), model: "m", modelMaxContext: 131072}
	d.latchDeterministicLoser(p, protocol.InferenceErrorMessage{
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: attempt.ErrorReasonRequestExceedsBatchBudget,
	})
	if d.unservable {
		t.Fatalf("a pressured (budget<context) batch-budget loser must NOT latch unservable")
	}
}

// TestShouldStopFailover_HonorsLatch (DAR-347 #2): once a deterministic loser has
// latched d.unservable, shouldStopFailover stops at the next retry point regardless
// of the surviving racer's (here transient) lastErr — the exact gap that let the
// speculative path keep storming. Fails without the d.unservable guard, which would
// classify "queue full" as a transient and keep failing over.
func TestShouldStopFailover_HonorsLatch(t *testing.T) {
	d := &execution{
		s: newTestController(t), model: "m",
		unservable: true, unservableReason: rejectionReasonOversized,
		lastErr: "request rejected: queue full", // a transient that alone would NOT stop failover
	}
	if !d.shouldStopFailover() {
		t.Fatalf("shouldStopFailover must honor a previously-latched unservable verdict")
	}
}
