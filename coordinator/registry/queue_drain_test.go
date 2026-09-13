package registry

// Regression tests for the queue-drain fleet-scan amplifier fix:
//
//   - per-pass dominance skip (queue_drain_dominance.go): a saturated pass pays
//     one fleet scan per distinct rejected request shape, not one per waiter,
//     while strictly smaller or differently constrained waiters are still
//     scanned (and admitted) in the same pass;
//   - heartbeat drain suppression (queue_drain_suppress.go): a heartbeat within
//     heartbeatDrainSuppressWindow of a saturated pass skips the model; every
//     capacity-freeing trigger drains synchronously as before;
//   - drain-pass coalescing (queue_drain_coalesce.go): a trigger that lands
//     while a pass holds popped waiters makes that pass rerun with fresh fleet
//     state instead of scanning an empty queue.
//
// Every test drives a real Registry with real providers and a real queue and
// counts full fleet scans through the reservationAfterScan hook, which fires
// exactly once per scanProviderReservation.

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const drainTestModel = "drain-test-model"

// drainTestProvider registers a routable budget-reporting provider for
// drainTestModel; used == max saturates it.
func drainTestProvider(t *testing.T, reg *Registry, id string, used, max int64) *Provider {
	t.Helper()
	return makeTokenBudgetProvider(t, reg, id, drainTestModel, 100, used, max, 50)
}

func drainTestSetBudget(p *Provider, used, max int64) {
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = used
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = max
	p.mu.Unlock()
}

// drainTestHeartbeat reports the given budget explicitly so the heartbeat
// itself never changes the provider's admission state.
func drainTestHeartbeat(used, max int64) *protocol.HeartbeatMessage {
	return &protocol.HeartbeatMessage{
		Type:       protocol.TypeHeartbeat,
		Status:     "serving",
		WarmModels: []string{drainTestModel},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{{
				Model:                 drainTestModel,
				State:                 "running",
				NumRunning:            1,
				ActiveTokenBudgetUsed: used,
				ActiveTokenBudgetMax:  max,
				ObservedDecodeTPS:     50,
			}},
		},
		SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
	}
}

func drainTestPending(id string, prompt, maxTok int) *PendingRequest {
	return &PendingRequest{
		RequestID:             id,
		Model:                 drainTestModel,
		EstimatedPromptTokens: prompt,
		RequestedMaxTokens:    maxTok,
	}
}

func drainTestEnqueue(t *testing.T, reg *Registry, pr *PendingRequest) *QueuedRequest {
	t.Helper()
	req := &QueuedRequest{RequestID: pr.RequestID, Model: pr.Model, Pending: pr}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue %s: %v", pr.RequestID, err)
	}
	return req
}

// drainScanCounter counts full fleet scans via the test-only
// reservationAfterScan barrier.
func drainScanCounter(reg *Registry) *atomic.Int64 {
	n := new(atomic.Int64)
	reg.reservationAfterScan = func(string) { n.Add(1) }
	return n
}

func drainTestQueueOrder(reg *Registry) []string {
	q := reg.Queue()
	q.mu.Lock()
	defer q.mu.Unlock()
	ids := make([]string, 0, len(q.queues[drainTestModel]))
	for _, req := range q.queues[drainTestModel] {
		ids = append(ids, req.RequestID)
	}
	return ids
}

func drainTestAwait(t *testing.T, reg *Registry, req *QueuedRequest) *Provider {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	p, err := reg.Queue().WaitForProviderContext(ctx, req)
	if err != nil {
		t.Fatalf("waiter %s: %v, want assignment", req.RequestID, err)
	}
	return p
}

func drainTestAssertQueued(t *testing.T, req *QueuedRequest) {
	t.Helper()
	select {
	case p := <-req.ResponseCh:
		t.Fatalf("waiter %s resolved early (provider=%v), want it kept queued", req.RequestID, p)
	default:
	}
	if req.FailureReason != nil {
		t.Fatalf("waiter %s FailureReason = %v, want nil", req.RequestID, req.FailureReason)
	}
}

func drainTestExpectScans(t *testing.T, scans *atomic.Int64, want int64, event string) {
	t.Helper()
	if got := scans.Swap(0); got != want {
		t.Fatalf("%s performed %d fleet scans, want %d", event, got, want)
	}
}

// TestDrainSaturatedQueueScansOncePerEvent is the core regression: with a
// saturated fleet and a full 32-deep queue of identical waiters, one heartbeat
// (and one SetProviderIdle) performs exactly ONE fleet scan instead of 32, and
// the queue is left intact and in order. Fails without the dominance skip.
func TestDrainSaturatedQueueScansOncePerEvent(t *testing.T) {
	reg := New(testLogger())
	for i := 0; i < 3; i++ {
		drainTestProvider(t, reg, fmt.Sprintf("sat-%d", i), 1000, 1000)
	}
	reg.SetQueue(NewRequestQueue(64, 30*time.Second))
	const depth = 32
	for i := 0; i < depth; i++ {
		drainTestEnqueue(t, reg, drainTestPending(fmt.Sprintf("q-%02d", i), 800, 1024))
	}
	scans := drainScanCounter(reg)

	reg.Heartbeat("sat-0", drainTestHeartbeat(1000, 1000))
	drainTestExpectScans(t, scans, 1, "heartbeat on a saturated fleet")
	order := drainTestQueueOrder(reg)
	if len(order) != depth {
		t.Fatalf("queue depth = %d after heartbeat, want %d", len(order), depth)
	}
	for i, id := range order {
		if want := fmt.Sprintf("q-%02d", i); id != want {
			t.Fatalf("queue[%d] = %s, want %s (order must survive the requeue)", i, id, want)
		}
	}

	// SetProviderIdle is never suppressed, and still pays exactly one scan.
	reg.SetProviderIdle("sat-1")
	drainTestExpectScans(t, scans, 1, "SetProviderIdle on a saturated fleet")
	if depth := reg.Queue().QueueSize(drainTestModel); depth != 32 {
		t.Fatalf("queue depth = %d after SetProviderIdle, want 32", depth)
	}
}

// TestDrainAdmitsWhenCapacityFreesAndSmallerWaiterIsNotBlocked pins the two
// behaviors the skip must not regress: a waiter IS assigned when capacity frees
// (SetProviderIdle after a budget release), and a strictly smaller waiter behind
// a larger rejected one is still scanned and admitted — in the same pass — the
// moment capacity for it appears, even while the larger one stays queued.
func TestDrainAdmitsWhenCapacityFreesAndSmallerWaiterIsNotBlocked(t *testing.T) {
	reg := New(testLogger())
	p := drainTestProvider(t, reg, "box", 990, 1000) // 10 tokens free
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	big := drainTestEnqueue(t, reg, drainTestPending("big", 800, 1024))
	small := drainTestEnqueue(t, reg, drainTestPending("small", 10, 16))
	scans := drainScanCounter(reg)

	// Neither fits in 10 free tokens. small is strictly smaller than big, so
	// it is scanned rather than skipped on big's verdict.
	reg.SetProviderIdle(p.ID)
	drainTestExpectScans(t, scans, 2, "SetProviderIdle with both waiters over capacity")
	drainTestAssertQueued(t, big)
	drainTestAssertQueued(t, small)
	if order := drainTestQueueOrder(reg); len(order) != 2 || order[0] != "big" || order[1] != "small" {
		t.Fatalf("queue order = %v, want [big small]", order)
	}

	// 100 tokens free: enough for small (26), not for big (1824).
	drainTestSetBudget(p, 900, 1000)
	reg.SetProviderIdle(p.ID)
	if got := drainTestAwait(t, reg, small); got.ID != p.ID {
		t.Fatalf("small assigned to %q, want %q", got.ID, p.ID)
	}
	drainTestAssertQueued(t, big)
	// big scanned+rejected, small scanned+admitted; big is re-popped after the
	// requeue and skipped on its own record: exactly two scans.
	drainTestExpectScans(t, scans, 2, "SetProviderIdle with capacity for the small waiter")
	if order := drainTestQueueOrder(reg); len(order) != 1 || order[0] != "big" {
		t.Fatalf("queue order = %v, want [big]", order)
	}

	// Full release: big is admitted too.
	drainTestSetBudget(p, 0, 32_768)
	reg.SetProviderIdle(p.ID)
	if got := drainTestAwait(t, reg, big); got.ID != p.ID {
		t.Fatalf("big assigned to %q, want %q", got.ID, p.ID)
	}
	if depth := reg.Queue().QueueSize(drainTestModel); depth != 0 {
		t.Fatalf("queue depth = %d after full release, want 0", depth)
	}
}

// TestDrainOwnerScopedHeadDoesNotBlockPublicWaiters is the fence against a
// plain "break on first rejection": a self-route waiter rejected on its owner's
// saturated box says nothing about public capacity, so the plain waiter behind
// it must still be scanned and assigned to the public provider.
func TestDrainOwnerScopedHeadDoesNotBlockPublicWaiters(t *testing.T) {
	reg := New(testLogger())
	owned := drainTestProvider(t, reg, "owned", 1000, 1000)
	owned.mu.Lock()
	owned.AccountID = "acct-1"
	owned.mu.Unlock()
	public := drainTestProvider(t, reg, "public", 0, 32_768)
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))

	selfPR := drainTestPending("self", 800, 1024)
	selfPR.SelfRouteOnly = true
	selfPR.OwnerAccountID = "acct-1"
	self := drainTestEnqueue(t, reg, selfPR)
	plain := drainTestEnqueue(t, reg, drainTestPending("plain", 800, 1024))
	scans := drainScanCounter(reg)

	reg.SetProviderIdle(public.ID)
	if got := drainTestAwait(t, reg, plain); got.ID != public.ID {
		t.Fatalf("plain waiter assigned to %q, want the public provider %q", got.ID, public.ID)
	}
	drainTestAssertQueued(t, self)
	// self (rejected, not a dominance anchor), plain (admitted), and self again
	// after the requeue: owner-scoped waiters are always scanned.
	if got := scans.Load(); got < 2 || got > 3 {
		t.Fatalf("pass performed %d fleet scans, want 2..3 (plain waiter must be scanned)", got)
	}
	if order := drainTestQueueOrder(reg); len(order) != 1 || order[0] != "self" {
		t.Fatalf("queue order = %v, want [self]", order)
	}
}

// drainTestClock installs a controllable clock on the suppressor so the window
// can be crossed without sleeping, and disables the trailing-pass scheduler:
// its goroutine would otherwise read the fake clock while the test advances
// it. Tests that exercise the trailing pass re-enable it explicitly.
type drainTestClockHandle struct{ v atomic.Pointer[time.Time] }

func (c *drainTestClockHandle) Add(d time.Duration) {
	t := c.v.Load().Add(d)
	c.v.Store(&t)
}

func drainTestClock(reg *Registry) *drainTestClockHandle {
	h := &drainTestClockHandle{}
	now := time.Now()
	h.v.Store(&now)
	reg.drainSuppress.now = func() time.Time { return *h.v.Load() }
	reg.drainSuppress.afterFunc = func(time.Duration, func()) {}
	return h
}

// TestHeartbeatDrainSuppressedAfterSaturatedPass pins the heartbeat window:
// after a saturated pass a heartbeat 1 ms later performs zero scans, every
// capacity-freeing trigger in between still drains, and once the window has
// elapsed the heartbeat drains again.
func TestHeartbeatDrainSuppressedAfterSaturatedPass(t *testing.T) {
	reg := New(testLogger())
	p := drainTestProvider(t, reg, "box", 1000, 1000)
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	for i := 0; i < 4; i++ {
		drainTestEnqueue(t, reg, drainTestPending(fmt.Sprintf("q-%d", i), 800, 1024))
	}
	scans := drainScanCounter(reg)
	clock := drainTestClock(reg)
	heartbeat := func() { reg.Heartbeat(p.ID, drainTestHeartbeat(1000, 1000)) }

	heartbeat()
	drainTestExpectScans(t, scans, 1, "first heartbeat")
	clock.Add(time.Millisecond)
	heartbeat()
	drainTestExpectScans(t, scans, 0, "second heartbeat 1 ms later")

	reg.SetProviderIdle(p.ID)
	drainTestExpectScans(t, scans, 1, "SetProviderIdle inside the window")
	heartbeat()
	drainTestExpectScans(t, scans, 0, "heartbeat right after SetProviderIdle")

	reg.RecordChallengeSuccess(p.ID)
	drainTestExpectScans(t, scans, 1, "RecordChallengeSuccess inside the window")
	reg.DrainQueuedRequestsForModel(drainTestModel)
	drainTestExpectScans(t, scans, 1, "explicit DrainQueuedRequestsForModel inside the window")

	clock.Add(heartbeatDrainSuppressWindow)
	heartbeat()
	drainTestExpectScans(t, scans, 1, "heartbeat after the window elapsed")
	if depth := reg.Queue().QueueSize(drainTestModel); depth != 4 {
		t.Fatalf("queue depth = %d, want 4 (fleet stayed saturated)", depth)
	}
}

// TestDrainAdmissionClearsHeartbeatSuppression: a pass that admits a request
// lifts the saturation mark, so the next heartbeat drains immediately instead
// of waiting out the window on a stale verdict.
func TestDrainAdmissionClearsHeartbeatSuppression(t *testing.T) {
	reg := New(testLogger())
	p := drainTestProvider(t, reg, "box", 1000, 1000)
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	first := drainTestEnqueue(t, reg, drainTestPending("first", 800, 1024))
	scans := drainScanCounter(reg)
	drainTestClock(reg)

	reg.Heartbeat(p.ID, drainTestHeartbeat(1000, 1000))
	drainTestExpectScans(t, scans, 1, "saturated heartbeat")
	if !reg.drainSuppress.suppressed(drainTestModel) {
		t.Fatal("model not marked saturated after a pure capacity rejection")
	}

	drainTestSetBudget(p, 0, 32_768)
	reg.SetProviderIdle(p.ID)
	if got := drainTestAwait(t, reg, first); got.ID != p.ID {
		t.Fatalf("first assigned to %q, want %q", got.ID, p.ID)
	}
	if reg.drainSuppress.suppressed(drainTestModel) {
		t.Fatal("saturation mark survived an admitting pass")
	}

	// Re-saturate and queue a new waiter: the very next heartbeat must scan.
	drainTestSetBudget(p, 1000, 1000)
	second := drainTestEnqueue(t, reg, drainTestPending("second", 800, 1024))
	scans.Store(0)
	reg.Heartbeat(p.ID, drainTestHeartbeat(1000, 1000))
	drainTestExpectScans(t, scans, 1, "heartbeat after the mark was cleared")
	drainTestAssertQueued(t, second)
}

// TestDrainDominated pins the dominance predicate: only a plain request that
// is no smaller on both size axes, with the same structural key and (when the
// anchor saw TTFT rejections) a ceiling no looser, is skipped.
func TestDrainDominated(t *testing.T) {
	anchorPR := drainTestPending("anchor", 800, 1024)
	anchorPR.MaxTTFTMs = 5000
	capacityOnly := RoutingDecision{CapacityRejections: 3}
	mixed := RoutingDecision{CapacityRejections: 2, TTFTRejections: 1}
	capRec, ok := drainRejectionRecordFor(anchorPR, capacityOnly)
	if !ok {
		t.Fatal("plain pure-capacity rejection must anchor dominance")
	}
	mixedRec, ok := drainRejectionRecordFor(anchorPR, mixed)
	if !ok {
		t.Fatal("plain mixed capacity/TTFT rejection must anchor dominance")
	}
	if _, ok := drainRejectionRecordFor(anchorPR, RoutingDecision{CandidateCount: 1}); ok {
		t.Fatal("commit-race verdict (CandidateCount > 0) must not anchor dominance")
	}
	if _, ok := drainRejectionRecordFor(anchorPR, RoutingDecision{VisionRejections: 2}); ok {
		t.Fatal("structural-only rejection must not anchor dominance")
	}
	selfPR := drainTestPending("self", 800, 1024)
	selfPR.SelfRouteOnly = true
	if _, ok := drainRejectionRecordFor(selfPR, capacityOnly); ok {
		t.Fatal("owner-scoped rejection must not anchor dominance")
	}

	cases := []struct {
		name string
		mut  func(pr *PendingRequest)
		rec  drainRejectionRecord
		want bool
	}{
		{"same size", func(*PendingRequest) {}, capRec, true},
		{"larger prompt and max", func(pr *PendingRequest) { pr.EstimatedPromptTokens = 900; pr.RequestedMaxTokens = 2048 }, capRec, true},
		{"smaller prompt", func(pr *PendingRequest) { pr.EstimatedPromptTokens = 799 }, capRec, false},
		{"smaller max", func(pr *PendingRequest) { pr.RequestedMaxTokens = 1023 }, capRec, false},
		{"default max normalizes", func(pr *PendingRequest) { pr.RequestedMaxTokens = 0 }, capRec, false},
		{"vision differs", func(pr *PendingRequest) { pr.RequiresVision = true }, capRec, false},
		{"traits differ", func(pr *PendingRequest) { pr.Traits.HasTools = true }, capRec, false},
		{"self-route", func(pr *PendingRequest) { pr.SelfRouteOnly = true }, capRec, false},
		{"prefer-owner", func(pr *PendingRequest) { pr.PreferOwner = true }, capRec, false},
		{"serial-pinned", func(pr *PendingRequest) { pr.AllowedProviderSerials = []string{"S1"} }, capRec, false},
		{"excluded providers", func(pr *PendingRequest) { pr.ExcludedProviderIDs = []string{"p1"} }, capRec, false},
		{"cache plan", func(pr *PendingRequest) {
			pr.CachePlan = CachePlan{
				ModelAggregateHash: "agg", PromptContractID: "contract", CacheScope: "scope",
				PromptTokenCount: 800, Boundaries: []protocol.PrefixCacheAnchor{{}},
			}
		}, capRec, false},
		{"capacity-only anchor ignores looser ceiling", func(pr *PendingRequest) { pr.MaxTTFTMs = 0 }, capRec, true},
		{"mixed anchor, same ceiling", func(*PendingRequest) {}, mixedRec, true},
		{"mixed anchor, tighter ceiling", func(pr *PendingRequest) { pr.MaxTTFTMs = 4000 }, mixedRec, true},
		{"mixed anchor, looser ceiling", func(pr *PendingRequest) { pr.MaxTTFTMs = 6000 }, mixedRec, false},
		{"mixed anchor, no ceiling", func(pr *PendingRequest) { pr.MaxTTFTMs = 0 }, mixedRec, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pr := drainTestPending("q", 800, 1024)
			pr.MaxTTFTMs = 5000
			tc.mut(pr)
			if got := drainDominated(pr, []drainRejectionRecord{tc.rec}); got != tc.want {
				t.Fatalf("drainDominated = %v, want %v", got, tc.want)
			}
		})
	}
	if drainDominated(drainTestPending("q", 800, 1024), nil) {
		t.Fatal("no anchors must never dominate")
	}
}

// TestQueueDrainSuppressorUnsuppressed pins the heartbeat model filter: the
// input slice is returned untouched when nothing is suppressed, suppressed
// models are dropped in order, and the window expires.
func TestQueueDrainSuppressorUnsuppressed(t *testing.T) {
	var s queueDrainSuppressor
	start := time.Now()
	now := start
	s.now = func() time.Time { return now }
	models := []string{"a", "b", "c"}
	if got := s.unsuppressed(models); len(got) != 3 || &got[0] != &models[0] {
		t.Fatalf("unsuppressed with no marks = %v, want the input slice", got)
	}
	s.markSaturated("b")
	now = start.Add(time.Millisecond)
	if got := s.unsuppressed(models); len(got) != 2 || got[0] != "a" || got[1] != "c" {
		t.Fatalf("unsuppressed = %v, want [a c]", got)
	}
	now = start
	s.markSaturated("a")
	s.markSaturated("c")
	now = start.Add(time.Millisecond)
	if got := s.unsuppressed(models); len(got) != 0 {
		t.Fatalf("unsuppressed with every model marked = %v, want empty", got)
	}
	now = start.Add(heartbeatDrainSuppressWindow)
	if got := s.unsuppressed(models); len(got) != 3 {
		t.Fatalf("unsuppressed after the window = %v, want all models", got)
	}
	now = start.Add(time.Millisecond)
	s.clear("b")
	if got := s.unsuppressed(models); len(got) != 1 || got[0] != "b" {
		t.Fatalf("unsuppressed after clear(b) = %v, want [b]", got)
	}
}

// TestHeartbeatDrainSuppressionArmsTrailingPass: a suppressed heartbeat is not
// dropped — it arms ONE end-of-window pass, so capacity that only a heartbeat
// could reveal is drained at most heartbeatDrainSuppressWindow late instead of
// waiting for the next un-suppressed trigger (the next heartbeat, 5 s away).
// Several suppressed heartbeats inside one window share a single trailing pass.
func TestHeartbeatDrainSuppressionArmsTrailingPass(t *testing.T) {
	reg := New(testLogger())
	p := drainTestProvider(t, reg, "box", 1000, 1000)
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	for i := 0; i < 4; i++ {
		drainTestEnqueue(t, reg, drainTestPending(fmt.Sprintf("q-%d", i), 800, 1024))
	}
	scans := drainScanCounter(reg)
	clock := drainTestClock(reg)
	// Real scheduler for this test; completion is observed through the seam
	// so the fake clock is never advanced while a trailing pass is running.
	reg.drainSuppress.afterFunc = nil
	done := make(chan string, 4)
	reg.drainSuppress.trailingDone = func(model string) { done <- model }
	heartbeat := func() { reg.Heartbeat(p.ID, drainTestHeartbeat(1000, 1000)) }
	waitTrailing := func(what string) {
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: trailing pass never ran", what)
		}
	}

	heartbeat()
	drainTestExpectScans(t, scans, 1, "first heartbeat")
	clock.Add(time.Millisecond)
	heartbeat()
	heartbeat()
	heartbeat()
	drainTestExpectScans(t, scans, 0, "three heartbeats inside the window")
	waitTrailing("first window")
	drainTestExpectScans(t, scans, 1, "trailing pass after the first window")

	// The trailing pass ended saturated again and the arm was consumed, so a
	// later suppressed heartbeat arms a fresh one.
	clock.Add(time.Millisecond)
	heartbeat()
	drainTestExpectScans(t, scans, 0, "heartbeat inside the second window")
	waitTrailing("second window")
	drainTestExpectScans(t, scans, 1, "trailing pass after the second window")
}

// TestDrainTriggerMidPassRerunsHeldWaiters pins the coalescing fence
// (queue_drain_coalesce.go). Pass A (SetProviderIdle) pops first — scanned and
// rejected on a saturated box — and second, skipped on first's verdict. Before
// A's next pop a heartbeat exposes the whole budget and runs its own drain,
// which finds the queue empty: both waiters are held by A. Without coalescing
// A requeues both on the stale verdict and nothing rescans them until the
// next trigger for the model; with it, the heartbeat's drain asks A to go
// around once more, and both waiters are assigned before SetProviderIdle
// returns — with the trailing-pass scheduler disabled, so a trailing drain
// cannot be what rescued them.
func TestDrainTriggerMidPassRerunsHeldWaiters(t *testing.T) {
	reg := New(testLogger())
	p := drainTestProvider(t, reg, "box", 1000, 1000)
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	first := drainTestEnqueue(t, reg, drainTestPending("first", 800, 1024))
	second := drainTestEnqueue(t, reg, drainTestPending("second", 800, 1024))
	scans := drainScanCounter(reg)
	drainTestClock(reg)

	pops := 0
	reg.drainBeforePop = func(model string) {
		pops++
		if pops == 3 {
			reg.Heartbeat(p.ID, drainTestHeartbeat(0, 32_768))
		}
	}
	reg.SetProviderIdle(p.ID)
	reg.drainBeforePop = nil

	if got := drainTestAwait(t, reg, first); got.ID != p.ID {
		t.Fatalf("first assigned to %q, want %q", got.ID, p.ID)
	}
	if got := drainTestAwait(t, reg, second); got.ID != p.ID {
		t.Fatalf("second assigned to %q, want %q", got.ID, p.ID)
	}
	// first scanned+rejected by A, nothing by the heartbeat's drain (the queue
	// was empty), both scanned+admitted by the rerun.
	drainTestExpectScans(t, scans, 3, "SetProviderIdle with a mid-pass heartbeat")
	// The rerun is attributed to the trigger that asked for it.
	if first.DrainTrigger != DrainTriggerHeartbeat || second.DrainTrigger != DrainTriggerHeartbeat {
		t.Fatalf("DrainTrigger = (%q, %q), want both %q (the rerun ran for the heartbeat)",
			first.DrainTrigger, second.DrainTrigger, DrainTriggerHeartbeat)
	}
	if depth := reg.Queue().QueueSize(drainTestModel); depth != 0 {
		t.Fatalf("queue depth = %d, want 0", depth)
	}
	if reg.drainSuppress.suppressed(drainTestModel) {
		t.Fatal("an admitting rerun left the saturation mark in place")
	}
}
