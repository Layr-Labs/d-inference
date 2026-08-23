package registry

// Drain-time TTFT failure regression tests (Codex P2, PR #512).
//
// A request that queued on a capacity rejection can later become PURELY
// TTFT-unservable: capacity frees but every dedicated/eligible provider fails
// only the hard-reject TTFT ceiling. That verdict is deterministic for the
// drain pass, so the waiter must be failed immediately with
// ErrQueueTTFTTooSlow instead of hanging until maxWait and surfacing a
// queue-timeout. Mixed rejections (a busy fast provider could still free up),
// owner-scoped waiters, and soft-gate (MaxTTFTMs=0) requests keep the old
// behavior.

import (
	"errors"
	"testing"
	"time"
)

const drainTTFTCeilingMs = 5000

// slowPrefill pins a crawling prefill rate so the provider's TTFT estimate for
// a ~100-token prompt (~500s) lands far above the 5s ceiling and the scheduler
// TTFT-rejects it.
func slowPrefill(p *Provider) {
	p.mu.Lock()
	p.PrefillTPS = 0.2
	p.mu.Unlock()
}

// saturateBudget exhausts the provider's slot token budget so routing rejects
// it for capacity (freeMemoryAdmits fails) before the TTFT ceiling is reached.
func saturateBudget(p *Provider) {
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 950
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1000
	p.mu.Unlock()
}

// freeBudget restores ample slot token budget.
func freeBudget(p *Provider) {
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 32_768
	p.mu.Unlock()
}

func enqueueTTFTWaiter(t *testing.T, reg *Registry, pr *PendingRequest) *QueuedRequest {
	t.Helper()
	req := &QueuedRequest{RequestID: pr.RequestID, Model: pr.Model, Pending: pr}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	return req
}

// TestDrainFailsPureTTFTRejectedWaiterPromptly is the core regression: the
// drain reserve fails ONLY on the TTFT gate, so the waiter must resolve
// immediately with ErrQueueTTFTTooSlow (carrying the decision for Retry-After),
// not requeue and wait out maxWait. Fails without the fix (ErrQueueTimeout
// after the full 2s maxWait).
func TestDrainFailsPureTTFTRejectedWaiterPromptly(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-drain-model"
	slowPrefill(makeSchedulerProvider(t, reg, "slow-box", model, 100))
	reg.SetQueue(NewRequestQueue(4, 2*time.Second))

	pr := &PendingRequest{
		RequestID:             "q-ttft-pure",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		MaxTTFTMs:             drainTTFTCeilingMs,
	}
	req := enqueueTTFTWaiter(t, reg, pr)

	reg.DrainQueuedRequestsForModel(model)

	select {
	case p := <-req.ResponseCh:
		if p != nil {
			t.Fatalf("terminal TTFT rejection assigned provider %q", p.ID)
		}
	default:
		t.Fatal("terminal TTFT rejection did not resolve the waiter synchronously")
	}
	err := req.FailureReason
	if !errors.Is(err, ErrQueueTTFTTooSlow) {
		t.Fatalf("waiter error = %v, want ErrQueueTTFTTooSlow", err)
	}
	if req.Decision.TTFTRejections == 0 {
		t.Fatal("Decision must carry the drain-time TTFT rejection tally")
	}
	if req.Decision.BestTTFTMs <= drainTTFTCeilingMs {
		t.Fatalf("Decision.BestTTFTMs = %v, want the over-ceiling estimate for Retry-After", req.Decision.BestTTFTMs)
	}
	if depth := reg.Queue().QueueSize(model); depth != 0 {
		t.Fatalf("queue depth = %d after terminal TTFT failure, want 0 (no requeue)", depth)
	}
}

// TestDrainMixedRejectionKeepsWaiting pins the mixed case: one provider is
// capacity-rejected (could free up) and another is TTFT-rejected. The waiter
// must stay queued, then complete on the busy provider once it frees.
func TestDrainMixedRejectionKeepsWaiting(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-mixed-model"
	busy := makeSchedulerProvider(t, reg, "busy-fast", model, 100)
	saturateBudget(busy)
	slowPrefill(makeSchedulerProvider(t, reg, "slow-box", model, 100))
	reg.SetQueue(NewRequestQueue(4, 5*time.Second))

	pr := &PendingRequest{
		RequestID:             "q-ttft-mixed",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		MaxTTFTMs:             drainTTFTCeilingMs,
	}
	req := enqueueTTFTWaiter(t, reg, pr)

	reg.DrainQueuedRequestsForModel(model)
	select {
	case p := <-req.ResponseCh:
		t.Fatalf("mixed rejection resolved the waiter early (provider=%v), want it kept queued", p)
	default:
	}
	if depth := reg.Queue().QueueSize(model); depth != 1 {
		t.Fatalf("queue depth = %d after mixed rejection, want 1 (requeued)", depth)
	}

	freeBudget(busy)
	reg.DrainQueuedRequestsForModel(model)

	select {
	case p := <-req.ResponseCh:
		if p == nil {
			t.Fatal("drain returned a nil provider after capacity became available")
		}
		if p.ID != busy.ID {
			t.Fatalf("assigned provider = %q, want the freed fast provider %q", p.ID, busy.ID)
		}
	default:
		t.Fatal("drain did not assign the freed provider synchronously")
	}
}

// TestDrainDoesNotTTFTFailOwnerScopedWaiters pins the owner-preservation guard:
// even with a (hypothetical) non-zero TTFT ceiling, prefer-owner and exclusive
// self-route waiters must never be TTFT-failed off the fleet verdict — they
// wait for their own box exactly as FailQueuedRequestsForModel preserves them.
func TestDrainDoesNotTTFTFailOwnerScopedWaiters(t *testing.T) {
	cases := []struct {
		name string
		mut  func(pr *PendingRequest)
	}{
		{"prefer_owner", func(pr *PendingRequest) { pr.PreferOwner = true; pr.OwnerAccountID = "acct-1" }},
		{"self_route", func(pr *PendingRequest) { pr.SelfRouteOnly = true; pr.OwnerAccountID = "acct-1" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			model := "ttft-owner-model-" + tc.name
			owned := makeSchedulerProvider(t, reg, "owned-slow", model, 100)
			slowPrefill(owned)
			owned.mu.Lock()
			owned.AccountID = "acct-1"
			owned.mu.Unlock()
			reg.SetQueue(NewRequestQueue(4, 5*time.Second))

			pr := &PendingRequest{
				RequestID:             "q-ttft-" + tc.name,
				Model:                 model,
				EstimatedPromptTokens: 100,
				RequestedMaxTokens:    128,
				MaxTTFTMs:             drainTTFTCeilingMs,
			}
			tc.mut(pr)
			req := enqueueTTFTWaiter(t, reg, pr)

			reg.DrainQueuedRequestsForModel(model)
			select {
			case <-req.ResponseCh:
				t.Fatal("owner-scoped waiter was resolved by a TTFT-only rejection, want it kept queued")
			default:
			}
			if req.FailureReason != nil {
				t.Fatalf("owner-scoped waiter FailureReason = %v, want nil", req.FailureReason)
			}
			if depth := reg.Queue().QueueSize(model); depth != 1 {
				t.Fatalf("queue depth = %d, want 1 (owner-scoped waiter requeued)", depth)
			}
		})
	}
}

// TestDrainSoftGateUnaffectedByTTFT pins the hard-reject-off behavior: with
// MaxTTFTMs=0 (queueMaxTTFTMs in soft mode) the scheduler never TTFT-rejects,
// so a slow-but-free provider SERVES the queued request, and a busy fleet
// requeues exactly as before — the drain never TTFT-fails a soft-gate waiter.
func TestDrainSoftGateUnaffectedByTTFT(t *testing.T) {
	reg := New(testLogger())
	model := "ttft-soft-model"
	slow := makeSchedulerProvider(t, reg, "slow-box", model, 100)
	slowPrefill(slow)
	reg.SetQueue(NewRequestQueue(4, 5*time.Second))

	pr := &PendingRequest{
		RequestID:             "q-ttft-soft",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	}
	req := enqueueTTFTWaiter(t, reg, pr)
	reg.DrainQueuedRequestsForModel(model)

	select {
	case p := <-req.ResponseCh:
		if p == nil {
			t.Fatal("soft-gate drain returned a nil provider")
		}
		if p.ID != slow.ID {
			t.Fatalf("assigned provider = %q, want %q", p.ID, slow.ID)
		}
	default:
		t.Fatal("soft-gate drain did not assign the provider synchronously")
	}

	// Busy soft-gate fleet: still a plain requeue (no TTFT failing).
	saturateBudget(slow)
	pr2 := &PendingRequest{
		RequestID:             "q-ttft-soft-busy",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	}
	req2 := enqueueTTFTWaiter(t, reg, pr2)
	reg.DrainQueuedRequestsForModel(model)
	if req2.FailureReason != nil {
		t.Fatalf("soft-gate busy waiter FailureReason = %v, want nil", req2.FailureReason)
	}
	if depth := reg.Queue().QueueSize(model); depth != 1 {
		t.Fatalf("queue depth = %d, want 1 (busy soft-gate waiter requeued)", depth)
	}
}
