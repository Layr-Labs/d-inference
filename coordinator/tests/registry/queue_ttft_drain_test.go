package registry_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"

	"sync"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func enqueueTTFTWaiter(t *testing.T, reg *production.Registry, pr *production.PendingRequest) *production.QueuedRequest {
	t.Helper()
	req := &production.QueuedRequest{RequestID: pr.RequestID, Model: pr.Model, Pending: pr}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}
	return req
}

func TestDrainRefreshesAbsoluteFirstContentBudgetBeforeReservation(t *testing.T) {
	reg := production.New(testLogger())
	model := "absolute-drain-budget"
	makeSchedulerProvider(t, reg, "fast-box", model, 100)
	reg.SetQueue(production.NewRequestQueue(4, 5*time.Second))

	pr := &production.PendingRequest{
		RequestID:             "q-absolute-refresh",
		Model:                 model,
		EstimatedPromptTokens: 1,
		RequestedMaxTokens:    32,
		MaxTTFTMs:             5_000,
		FirstContentDeadline:  time.Now().Add(2 * time.Second),
	}
	req := enqueueTTFTWaiter(t, reg, pr)
	time.Sleep(60 * time.Millisecond)
	reg.DrainQueuedRequestsForModel(model)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := reg.Queue().WaitForProviderContext(ctx, req); err != nil {
		t.Fatalf("waiter assignment: %v", err)
	}
	if pr.MaxTTFTMs <= 0 || pr.MaxTTFTMs >= 1_980 {
		t.Fatalf("drain MaxTTFTMs = %.1f, want refreshed remaining budget", pr.MaxTTFTMs)
	}
	if pr.FirstContentBudgetMS <= 0 ||
		float64(pr.FirstContentBudgetMS) != pr.MaxTTFTMs {
		t.Fatalf(
			"wire budget=%d MaxTTFTMs=%.1f, want one refreshed clock",
			pr.FirstContentBudgetMS, pr.MaxTTFTMs)
	}
}

func TestDrainRejectsExpiredAbsoluteFirstContentDeadline(t *testing.T) {
	reg := production.New(testLogger())
	model := "expired-drain-budget"
	makeSchedulerProvider(t, reg, "fast-box", model, 100)
	reg.SetQueue(production.NewRequestQueue(4, 5*time.Second))

	pr := &production.PendingRequest{
		RequestID:             "q-absolute-expired",
		Model:                 model,
		EstimatedPromptTokens: 1,
		RequestedMaxTokens:    32,
		MaxTTFTMs:             5_000,
		FirstContentDeadline:  time.Now().Add(-time.Millisecond),
	}
	req := enqueueTTFTWaiter(t, reg, pr)
	reg.DrainQueuedRequestsForModel(model)

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := reg.Queue().WaitForProviderContext(ctx, req); !errors.Is(
		err, production.ErrQueueFirstContentDeadline) {
		t.Fatalf("expired waiter error = %v, want absolute deadline", err)
	}
	if depth := reg.Queue().QueueSize(model); depth != 0 {
		t.Fatalf("expired queue depth = %d, want 0", depth)
	}
}

func TestQueueCancellationAfterReservationOfferReleasesProvider(t *testing.T) {
	var claims *drainClaimConsumer
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{
		QueueClaims: func(queue *production.RequestQueue) production.QueueClaims {
			claims = &drainClaimConsumer{actual: queue}
			return claims
		},
	})
	const model = "queue-handoff-cancel-model"
	provider := makeSchedulerProvider(t, reg, "queue-handoff-provider", model, 100)
	reg.SetQueue(production.NewRequestQueue(4, time.Second))

	offered := make(chan struct{})
	releaseSend := make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseSend) }) }
	defer release()
	claims.afterOffer = func() {
		close(offered)
		<-releaseSend
	}
	pr := &production.PendingRequest{
		RequestID:             "queue-handoff-request",
		Model:                 model,
		EstimatedPromptTokens: 32,
		RequestedMaxTokens:    32,
	}
	req := &production.QueuedRequest{
		RequestID: pr.RequestID,
		Model:     model,
		Pending:   pr,
		// Keep the scheduler at the ownership boundary until cancellation has
		// run, making the former buffered-send leak race deterministic.
		ResponseCh: make(chan *production.Provider),
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	waitErr := make(chan error, 1)
	go func() {
		_, err := reg.Queue().WaitForProviderContext(ctx, req)
		waitErr <- err
	}()
	drainDone := make(chan struct{})
	go func() {
		defer close(drainDone)
		reg.DrainQueuedRequestsForModel(model)
	}()

	select {
	case <-offered:
	case <-time.After(time.Second):
		t.Fatal("scheduler did not publish reservation offer")
	}
	if provider.PendingCount() != 1 {
		t.Fatalf("pending count before cancellation = %d, want 1", provider.PendingCount())
	}

	cancel()
	select {
	case err := <-waitErr:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("wait error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled queue waiter did not return")
	}
	release()
	select {
	case <-drainDone:
	case <-time.After(time.Second):
		t.Fatal("queue drain did not finish after cancellation")
	}

	if provider.PendingCount() != 0 {
		t.Fatalf("pending count after cancellation = %d, want 0", provider.PendingCount())
	}
	provider.Mu().Lock()
	status := provider.Status
	provider.Mu().Unlock()
	if status == production.StatusServing {
		t.Fatalf("provider remained busy after rejected handoff: %s", status)
	}
}

const drainTTFTCeilingMs = 5000

// slowPrefill pins a crawling prefill rate so the provider's TTFT estimate for
// a ~100-token prompt (~500s) lands far above the 5s ceiling and the scheduler
// TTFT-rejects it.
func slowPrefill(reg *production.Registry, p *production.Provider) {
	p.Mu().Lock()
	p.PrefillTPS = 0.2
	slot := p.BackendCapacity.Slots[0]
	metrics := p.SystemMetrics
	p.Mu().Unlock()
	// Two changed legacy reports establish the same bounded freshness evidence
	// through the real heartbeat acceptance path, rather than seeding its map.
	for _, sample := range []struct{ prefill, decode float64 }{{0.1, 99}, {0.2, 100}} {
		zero, initialized, rate := int64(0), true, sample.prefill
		slot.ObservedDecodeTPS = sample.decode
		slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: &zero, PartialPrefillRows: &zero, IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
		reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, Status: "serving", SystemMetrics: metrics,
			BackendCapacity: &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: []protocol.BackendSlotCapacity{slot}}})
	}
}

// saturateBudget exhausts the provider's slot token budget so routing rejects
// it for capacity (freeMemoryAdmits fails) before the TTFT ceiling is reached.
func saturateBudget(p *production.Provider) {
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 950
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1000
	p.Mu().Unlock()
}

// freeBudget restores ample slot token budget.
func freeBudget(p *production.Provider) {
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 32_768
	p.Mu().Unlock()
}

// TestDrainFailsPureTTFTRejectedWaiterPromptly is the core regression: the
// drain reserve fails ONLY on the TTFT gate, so the waiter must resolve
// immediately with ErrQueueTTFTTooSlow (carrying the decision for Retry-After),
// not requeue and wait out maxWait. Fails without the fix (ErrQueueTimeout
// after the full 2s maxWait).
func TestDrainFailsPureTTFTRejectedWaiterPromptly(t *testing.T) {
	reg := production.New(testLogger())
	model := "ttft-drain-model"
	slowPrefill(reg, makeSchedulerProvider(t, reg, "slow-box", model, 100))
	reg.SetQueue(production.NewRequestQueue(4, 2*time.Second))

	pr := &production.PendingRequest{
		RequestID:             "q-ttft-pure",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
		MaxTTFTMs:             drainTTFTCeilingMs,
	}
	req := enqueueTTFTWaiter(t, reg, pr)

	start := time.Now()
	reg.DrainQueuedRequestsForModel(model)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, err := reg.Queue().WaitForProviderContext(ctx, req)
	elapsed := time.Since(start)

	if !errors.Is(err, production.ErrQueueTTFTTooSlow) {
		t.Fatalf("waiter error = %v, want ErrQueueTTFTTooSlow", err)
	}
	if elapsed > time.Second {
		t.Fatalf("waiter resolved in %v, want prompt failure well under maxWait", elapsed)
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
	reg := production.New(testLogger())
	model := "ttft-mixed-model"
	busy := makeSchedulerProvider(t, reg, "busy-fast", model, 100)
	saturateBudget(busy)
	slowPrefill(reg, makeSchedulerProvider(t, reg, "slow-box", model, 100))
	reg.SetQueue(production.NewRequestQueue(4, 5*time.Second))

	pr := &production.PendingRequest{
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

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	p, err := reg.Queue().WaitForProviderContext(ctx, req)
	if err != nil {
		t.Fatalf("waiter error = %v, want assignment after the busy provider freed", err)
	}
	if p.ID != busy.ID {
		t.Fatalf("assigned provider = %q, want the freed fast provider %q", p.ID, busy.ID)
	}
}

// TestDrainDoesNotTTFTFailOwnerScopedWaiters pins the owner-preservation guard:
// even with a (hypothetical) non-zero TTFT ceiling, prefer-owner and exclusive
// self-route waiters must never be TTFT-failed off the fleet verdict — they
// wait for their own box exactly as FailQueuedRequestsForModel preserves them.
func TestDrainDoesNotTTFTFailOwnerScopedWaiters(t *testing.T) {
	cases := []struct {
		name string
		mut  func(pr *production.PendingRequest)
	}{
		{"prefer_owner", func(pr *production.PendingRequest) { pr.PreferOwner = true; pr.OwnerAccountID = "acct-1" }},
		{"self_route", func(pr *production.PendingRequest) { pr.SelfRouteOnly = true; pr.OwnerAccountID = "acct-1" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := production.New(testLogger())
			model := "ttft-owner-model-" + tc.name
			owned := makeSchedulerProvider(t, reg, "owned-slow", model, 100)
			slowPrefill(reg, owned)
			owned.Mu().Lock()
			owned.AccountID = "acct-1"
			owned.Mu().Unlock()
			reg.SetQueue(production.NewRequestQueue(4, 5*time.Second))

			pr := &production.PendingRequest{
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
	reg := production.New(testLogger())
	model := "ttft-soft-model"
	slow := makeSchedulerProvider(t, reg, "slow-box", model, 100)
	slowPrefill(reg, slow)
	reg.SetQueue(production.NewRequestQueue(4, 5*time.Second))

	pr := &production.PendingRequest{
		RequestID:             "q-ttft-soft",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    128,
	}
	req := enqueueTTFTWaiter(t, reg, pr)
	reg.DrainQueuedRequestsForModel(model)

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	p, err := reg.Queue().WaitForProviderContext(ctx, req)
	if err != nil {
		t.Fatalf("soft-gate waiter error = %v, want the best-available provider", err)
	}
	if p.ID != slow.ID {
		t.Fatalf("assigned provider = %q, want %q", p.ID, slow.ID)
	}

	// Busy soft-gate fleet: still a plain requeue (no TTFT failing).
	saturateBudget(slow)
	pr2 := &production.PendingRequest{
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
