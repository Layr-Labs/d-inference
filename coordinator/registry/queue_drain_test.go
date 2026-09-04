package registry

// Regression tests for the queue-drain fleet-scan amplifier fix:
//
//   - per-pass dominance skip (queue_drain_dominance.go): a saturated pass pays
//     one fleet scan per distinct rejected request shape, not one per waiter,
//     while strictly smaller or differently constrained waiters are still
//     scanned (and admitted) in the same pass;
//   - heartbeat drain suppression (queue_drain_suppress.go): a heartbeat within
//     heartbeatDrainSuppressWindow of a saturated pass skips the model and arms
//     one trailing pass; every capacity-freeing trigger drains synchronously
//     as before.
//
// Every test drives a real Registry with real providers and a real queue and
// counts full fleet scans through the reservationAfterScan hook, which fires
// exactly once per scanProviderReservation.

import (
	"context"
	"errors"
	"fmt"
	"sync"
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
	return drainTestHeartbeatFor(drainTestModel, used, max)
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

func drainTestQueueOrder(reg *Registry, model string) []string {
	q := reg.Queue()
	q.mu.Lock()
	defer q.mu.Unlock()
	ids := make([]string, 0, len(q.queues[model]))
	for _, req := range q.queues[model] {
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
// the queue is left intact and in order. Requeued waiters carry no drain
// stamps — the same as master, where only admitted or terminally failed
// waiters are stamped. Fails without the dominance skip.
func TestDrainSaturatedQueueScansOncePerEvent(t *testing.T) {
	reg := New(testLogger())
	for i := 0; i < 3; i++ {
		drainTestProvider(t, reg, fmt.Sprintf("sat-%d", i), 1000, 1000)
	}
	reg.SetQueue(NewRequestQueue(64, 30*time.Second))
	const depth = 32
	waiters := make([]*QueuedRequest, 0, depth)
	for i := 0; i < depth; i++ {
		waiters = append(waiters, drainTestEnqueue(t, reg, drainTestPending(fmt.Sprintf("q-%02d", i), 800, 1024)))
	}
	scans := drainScanCounter(reg)

	reg.Heartbeat("sat-0", drainTestHeartbeat(1000, 1000))
	drainTestExpectScans(t, scans, 1, "heartbeat on a saturated fleet")
	order := drainTestQueueOrder(reg, drainTestModel)
	if len(order) != depth {
		t.Fatalf("queue depth = %d after heartbeat, want %d", len(order), depth)
	}
	for i, id := range order {
		if want := fmt.Sprintf("q-%02d", i); id != want {
			t.Fatalf("queue[%d] = %s, want %s (order must survive the requeue)", i, id, want)
		}
	}
	for _, w := range waiters {
		if w.DrainTrigger != "" || w.Decision.DrainTrigger != "" {
			t.Fatalf("requeued waiter %s carries drain stamps (%q/%q); master stamps only admitted/failed waiters",
				w.RequestID, w.DrainTrigger, w.Decision.DrainTrigger)
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
	if order := drainTestQueueOrder(reg, drainTestModel); len(order) != 2 || order[0] != "big" || order[1] != "small" {
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
	if order := drainTestQueueOrder(reg, drainTestModel); len(order) != 1 || order[0] != "big" {
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
	if order := drainTestQueueOrder(reg, drainTestModel); len(order) != 1 || order[0] != "self" {
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
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
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
	expectMetric(t, sink, 1, "queue.drain.suppressed", "trigger:heartbeat")

	reg.SetProviderIdle(p.ID)
	drainTestExpectScans(t, scans, 1, "SetProviderIdle inside the window")
	heartbeat()
	drainTestExpectScans(t, scans, 0, "heartbeat right after SetProviderIdle")

	// A steady-state challenge success (already fresh, SIP already verified)
	// performs no drain at all (RecordChallengeSuccess drains only on a state
	// transition), so drive the transition that does: the first success after
	// registration, which flips the SIP gate. That drain must bypass the
	// heartbeat window like every other capacity-freeing trigger.
	p.mu.Lock()
	p.ChallengeVerifiedSIP = false
	p.mu.Unlock()
	reg.RecordChallengeSuccess(p.ID)
	drainTestExpectScans(t, scans, 1, "RecordChallengeSuccess inside the window")
	reg.DrainQueuedRequestsForModel(drainTestModel)
	drainTestExpectScans(t, scans, 1, "explicit DrainQueuedRequestsForModel inside the window")
	reg.DrainQueuedRequestsForModelWithReason(drainTestModel, DrainTriggerLoad)
	drainTestExpectScans(t, scans, 1, "load-success drain inside the window")

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
// Several suppressed heartbeats inside one window share a single trailing
// pass, and the trailing pass is stamped as a heartbeat drain.
func TestHeartbeatDrainSuppressionArmsTrailingPass(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
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
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:heartbeat", "outcome:saturated")
	expectMetric(t, sink, 3, "queue.drain.dominated", "trigger:heartbeat")
	clock.Add(time.Millisecond)
	heartbeat()
	heartbeat()
	heartbeat()
	drainTestExpectScans(t, scans, 0, "three heartbeats inside the window")
	expectMetric(t, sink, 3, "queue.drain.suppressed", "trigger:heartbeat")
	waitTrailing("first window")
	drainTestExpectScans(t, scans, 1, "trailing pass after the first window")
	// The trailing pass is a heartbeat-attributed pass of its own.
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:heartbeat", "outcome:saturated")
	expectMetric(t, sink, 3, "queue.drain.dominated", "trigger:heartbeat")

	// The trailing pass ended saturated again and the arm was consumed, so a
	// later suppressed heartbeat arms a fresh one.
	clock.Add(time.Millisecond)
	heartbeat()
	drainTestExpectScans(t, scans, 0, "heartbeat inside the second window")
	waitTrailing("second window")
	drainTestExpectScans(t, scans, 1, "trailing pass after the second window")
}

// TestDrainLostWakeupRecoveredByTrailingPass documents the one window the
// dominance skip changes. No lock spans a pass, so a capacity-freeing drain
// (SetProviderIdle) that runs while pass A holds every waiter in `skipped`
// finds an empty queue and admits nothing. Master recovered that at the next
// waiter's scan inside pass A; with the skip, pass A requeues on its stale
// verdict and the capacity is picked up by the next trigger — here a
// suppressed heartbeat's trailing pass, within heartbeatDrainSuppressWindow.
func TestDrainLostWakeupRecoveredByTrailingPass(t *testing.T) {
	reg := New(testLogger())
	p := drainTestProvider(t, reg, "box", 1000, 1000)
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	first := drainTestEnqueue(t, reg, drainTestPending("q-0", 800, 1024))
	second := drainTestEnqueue(t, reg, drainTestPending("q-1", 800, 1024))
	scans := drainScanCounter(reg)
	clock := drainTestClock(reg)
	reg.drainSuppress.afterFunc = nil
	trailing := make(chan string, 2)
	reg.drainSuppress.trailingDone = func(model string) { trailing <- model }

	// Park pass A (a heartbeat) once it has popped every waiter and is about
	// to requeue them — the window in which the queue is momentarily empty.
	parked := make(chan struct{})
	release := make(chan struct{})
	var parkedOnce atomic.Bool // CAS, not sync.Once: pass B must not block on pass A's park
	reg.drainPassBeforeRequeue = func(string) {
		if parkedOnce.CompareAndSwap(false, true) {
			close(parked)
			<-release
		}
	}
	passA := make(chan struct{})
	go func() {
		defer close(passA)
		reg.Heartbeat(p.ID, drainTestHeartbeat(1000, 1000))
	}()
	select {
	case <-parked:
	case <-time.After(2 * time.Second):
		t.Fatal("pass A never reached the requeue window")
	}
	drainTestExpectScans(t, scans, 1, "pass A (one scan, second waiter dominated)")

	// Capacity frees while pass A is parked: the idle drain finds nothing to
	// pop and admits nothing (the lost wakeup).
	drainTestSetBudget(p, 0, 32_768)
	reg.SetProviderIdle(p.ID)
	drainTestExpectScans(t, scans, 0, "SetProviderIdle against the momentarily empty queue")
	drainTestAssertQueued(t, first)
	drainTestAssertQueued(t, second)

	close(release)
	<-passA
	if order := drainTestQueueOrder(reg, drainTestModel); len(order) != 2 {
		t.Fatalf("queue order after pass A = %v, want both waiters requeued", order)
	}
	if !reg.drainSuppress.suppressed(drainTestModel) {
		t.Fatal("pass A did not mark the model saturated on its stale verdict")
	}

	// The next heartbeat inside the window is suppressed but arms the trailing
	// pass, which sees the freed capacity and admits both waiters.
	clock.Add(time.Millisecond)
	reg.Heartbeat(p.ID, drainTestHeartbeat(0, 32_768))
	drainTestExpectScans(t, scans, 0, "suppressed heartbeat")
	select {
	case <-trailing:
	case <-time.After(2 * time.Second):
		t.Fatal("trailing pass never ran")
	}
	if got := drainTestAwait(t, reg, first); got.ID != p.ID {
		t.Fatalf("first assigned to %q, want %q", got.ID, p.ID)
	}
	if got := drainTestAwait(t, reg, second); got.ID != p.ID {
		t.Fatalf("second assigned to %q, want %q", got.ID, p.ID)
	}
}

// TestDrainCancelledWhileOfferedNestedDrainIsOneScanPerModel: a waiter that
// cancels after the scheduler offered it a reservation releases the
// reservation exactly once, and the SetProviderIdle drain that release runs
// from inside the pass costs exactly one scan per model the provider serves —
// even with a saturated queue on the provider's other model (master paid one
// scan per waiter there).
func TestDrainCancelledWhileOfferedNestedDrainIsOneScanPerModel(t *testing.T) {
	reg := New(testLogger())
	const other = "drain-test-other-model"
	p := drainTestProvider(t, reg, "box", 0, 32_768)
	addAdvertisedModel(p, other)
	p.mu.Lock()
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model: other, State: "running", NumRunning: 1,
		ActiveTokenBudgetUsed: 1000, ActiveTokenBudgetMax: 1000, ObservedDecodeTPS: 50,
	})
	p.mu.Unlock()
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	for i := 0; i < 4; i++ {
		id := fmt.Sprintf("other-%d", i)
		req := &QueuedRequest{RequestID: id, Model: other, Pending: &PendingRequest{
			RequestID: id, Model: other, EstimatedPromptTokens: 800, RequestedMaxTokens: 1024}}
		if err := reg.Queue().Enqueue(req); err != nil {
			t.Fatal(err)
		}
	}

	offered := make(chan struct{})
	releaseSend := make(chan struct{})
	pr := drainTestPending("cancelled", 32, 32)
	req := &QueuedRequest{
		RequestID: pr.RequestID, Model: drainTestModel, Pending: pr,
		ResponseCh: make(chan *Provider),
		beforeAssignmentSend: func() {
			close(offered)
			<-releaseSend
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatal(err)
	}
	scans := drainScanCounter(reg)

	ctx, cancel := context.WithCancel(context.Background())
	waitErr := make(chan error, 1)
	go func() {
		_, err := reg.Queue().WaitForProviderContext(ctx, req)
		waitErr <- err
	}()
	drainDone := make(chan struct{})
	go func() {
		reg.DrainQueuedRequestsForModel(drainTestModel)
		close(drainDone)
	}()
	select {
	case <-offered:
	case <-time.After(time.Second):
		t.Fatal("scheduler did not publish the reservation offer")
	}
	if p.PendingCount() != 1 {
		t.Fatalf("pending count before cancellation = %d, want 1", p.PendingCount())
	}
	cancel()
	select {
	case err := <-waitErr:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("wait error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancelled waiter did not return")
	}
	close(releaseSend)
	select {
	case <-drainDone:
	case <-time.After(time.Second):
		t.Fatal("drain did not finish after cancellation")
	}
	if p.PendingCount() != 0 {
		t.Fatalf("pending count after cancellation = %d, want 0 (released exactly once)", p.PendingCount())
	}
	// One scan admitted the cancelled waiter; the nested SetProviderIdle drain
	// scanned the saturated other-model queue exactly once (four waiters).
	drainTestExpectScans(t, scans, 2, "offer + nested release drain")
	if depth := reg.Queue().QueueSize(other); depth != 4 {
		t.Fatalf("other-model queue depth = %d, want 4", depth)
	}
}

// TestDisconnectDrainScansOncePerModelAndFailsConstrainedWaiter: Disconnect
// re-runs the drain for the departed provider's models. With plain waiters on
// a still-saturated fleet it costs one scan and leaves the order intact; a
// RequiresToolConstraint waiter whose last capable provider just left is
// failed within the Disconnect call, stamped disconnect.
func TestDisconnectDrainScansOncePerModelAndFailsConstrainedWaiter(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	stay := drainTestProvider(t, reg, "stay", 1000, 1000)
	leave := drainTestProvider(t, reg, "leave", 1000, 1000)
	setProviderVersion(stay, "0.8.15")
	setProviderVersion(leave, "0.8.15")
	reg.MergeProviderModelsWithCapabilities(leave.ID,
		[]protocol.ModelInfo{{ID: drainTestModel, ModelType: "chat", Quantization: "4bit"}},
		ToolConstraintProtocolV1, []string{drainTestModel})
	if candidates, capacity, _ := reg.QuickCapacityCheck(drainTestModel, 10, 32,
		RequestTraits{HasTools: true, RequiresToolConstraint: true}); candidates != 0 || capacity != 1 {
		t.Fatalf("fixture: constrained preflight = %d candidates / %d capacity-rejected, want 0/1 (leave is capable but saturated)", candidates, capacity)
	}
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	plain := make([]*QueuedRequest, 0, 4)
	for i := 0; i < 4; i++ {
		plain = append(plain, drainTestEnqueue(t, reg, drainTestPending(fmt.Sprintf("q-%d", i), 800, 1024)))
	}
	constrainedPR := drainTestPending("constrained", 800, 1024)
	constrainedPR.Traits = RequestTraits{HasTools: true, RequiresToolConstraint: true}
	constrained := drainTestEnqueue(t, reg, constrainedPR)
	scans := drainScanCounter(reg)

	reg.Disconnect(leave.ID)

	select {
	case got := <-constrained.ResponseCh:
		if got != nil || !errors.Is(constrained.FailureReason, ErrQueueToolConstraintUnavailable) {
			t.Fatalf("constrained waiter resolved with provider=%v reason=%v, want ErrQueueToolConstraintUnavailable", got, constrained.FailureReason)
		}
	default:
		t.Fatal("constrained waiter was not failed within the Disconnect call")
	}
	if constrained.DrainTrigger != DrainTriggerDisconnect || constrained.Decision.DrainTrigger != DrainTriggerDisconnect {
		t.Fatalf("constrained waiter stamps = %q/%q, want disconnect", constrained.DrainTrigger, constrained.Decision.DrainTrigger)
	}
	// Four plain identical waiters: one scan, three dominated. The constrained
	// waiter is a different shape and pays its own scan before its fast-fail.
	drainTestExpectScans(t, scans, 2, "Disconnect drain")
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:disconnect", "outcome:saturated")
	expectMetric(t, sink, 3, "queue.drain.dominated", "trigger:disconnect")
	order := drainTestQueueOrder(reg, drainTestModel)
	if len(order) != 4 {
		t.Fatalf("queue after Disconnect = %v, want the four plain waiters", order)
	}
	for i, id := range order {
		if want := fmt.Sprintf("q-%d", i); id != want {
			t.Fatalf("queue[%d] = %s, want %s", i, id, want)
		}
	}
	for _, w := range plain {
		drainTestAssertQueued(t, w)
	}
	_ = stay
}

// TestDrainConcurrentTriggersRace runs heartbeats, SetProviderIdle,
// disconnect/re-register, enqueues and cancels concurrently against one
// registry; it exists for -race and asserts only invariants (no deadlock,
// every waiter resolved or still queued, pending counts back to zero).
func TestDrainConcurrentTriggersRace(t *testing.T) {
	reg := New(testLogger())
	providers := make([]*Provider, 0, 4)
	for i := 0; i < 4; i++ {
		providers = append(providers, drainTestProvider(t, reg, fmt.Sprintf("box-%d", i), 900, 1000))
	}
	reg.SetQueue(NewRequestQueue(64, 30*time.Second))
	reg.drainSuppress.trailingDone = nil

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	var wg sync.WaitGroup
	for _, p := range providers {
		p := p
		wg.Add(1)
		go func() {
			defer wg.Done()
			i := 0
			for ctx.Err() == nil {
				if i%3 == 0 {
					reg.Heartbeat(p.ID, drainTestHeartbeat(900, 1000))
				} else {
					drainTestSetBudget(p, int64(900-(i%5)*50), 1000)
					reg.SetProviderIdle(p.ID)
				}
				i++
			}
		}()
	}
	var enqueued atomic.Int64
	wg.Add(1)
	go func() {
		defer wg.Done()
		i := 0
		for ctx.Err() == nil {
			pr := drainTestPending(fmt.Sprintf("w-%d", i), 10+(i%4)*200, 16+(i%3)*300)
			req := &QueuedRequest{RequestID: pr.RequestID, Model: pr.Model, Pending: pr}
			if err := reg.Queue().Enqueue(req); err == nil {
				enqueued.Add(1)
				wctx, wcancel := context.WithTimeout(ctx, time.Duration(i%7)*time.Millisecond)
				if p, err := reg.Queue().WaitForProviderContext(wctx, req); err == nil && p != nil {
					p.RemovePending(pr.RequestID)
					reg.SetProviderIdle(p.ID)
				}
				wcancel()
			}
			i++
		}
	}()
	wg.Wait()
	if enqueued.Load() == 0 {
		t.Fatal("no waiter was ever enqueued")
	}
	// Let any in-flight trailing pass finish before the registry is dropped.
	time.Sleep(2 * heartbeatDrainSuppressWindow)
	for _, p := range providers {
		if n := p.PendingCount(); n != 0 {
			t.Fatalf("%s pending count = %d after the run, want 0", p.ID, n)
		}
	}
}

// TestDrainSaturatedPassAllocBudget is the deterministic cost gate: one
// heartbeat over a saturated fleet with 32 identical waiters performs one
// fleet scan and allocates on the order of one scan plus the per-waiter
// requeue bookkeeping — strictly less than the same pass with the dominance
// skip disabled (32 scans). Measured with the metrics sink installed (prod
// shape). The fleet-scale numbers live in queue_drain_bench_test.go.
func TestDrainSaturatedPassAllocBudget(t *testing.T) {
	reg := New(testLogger())
	reg.SetMetricsSink(newRecordingMetricsSink())
	for i := 0; i < 8; i++ {
		drainTestProvider(t, reg, fmt.Sprintf("sat-%d", i), 1000, 1000)
	}
	reg.SetQueue(NewRequestQueue(64, 30*time.Second))
	const depth = 32
	for i := 0; i < depth; i++ {
		drainTestEnqueue(t, reg, drainTestPending(fmt.Sprintf("q-%02d", i), 800, 1024))
	}
	scans := drainScanCounter(reg)
	// Cross the suppression window before each measured heartbeat so every
	// sample is a real (unsuppressed) pass.
	clock := drainTestClock(reg)
	hb := drainTestHeartbeat(1000, 1000)

	scanAllocs := testing.AllocsPerRun(20, func() {
		pr := drainTestPending("probe", 800, 1024)
		if p, _ := reg.ReserveProviderEx(drainTestModel, pr); p != nil {
			t.Fatal("fixture admitted a request; want saturation")
		}
	})
	measure := func(dominance bool) (allocs float64, scansPerPass int64) {
		reg.drainDominanceDisabled = !dominance
		scans.Store(0)
		allocs = testing.AllocsPerRun(20, func() {
			clock.Add(heartbeatDrainSuppressWindow)
			reg.Heartbeat("sat-0", hb)
		})
		// AllocsPerRun executes the function once as a warm-up plus 20 runs.
		return allocs, scans.Load() / 21
	}
	beforeAllocs, beforeScans := measure(false)
	afterAllocs, afterScans := measure(true)
	if beforeScans != depth {
		t.Fatalf("pre-dominance pass performed %d scans per pass, want %d (one per waiter)", beforeScans, depth)
	}
	if afterScans != 1 {
		t.Fatalf("dominance pass performed %d scans per pass, want 1", afterScans)
	}
	// Absolute budget: one scan + O(depth) requeue/skip bookkeeping + tags.
	ceiling := scanAllocs + 3*depth + 32
	if afterAllocs > ceiling {
		t.Fatalf("saturated heartbeat pass = %.0f allocs/op, want <= %.0f (one scan = %.0f)", afterAllocs, ceiling, scanAllocs)
	}
	if afterAllocs >= beforeAllocs {
		t.Fatalf("dominance pass = %.0f allocs/op, not below the %.0f of the %d-scan pass", afterAllocs, beforeAllocs, depth)
	}
	t.Logf("saturated pass (depth %d): %.0f allocs/op with dominance vs %.0f without; one scan = %.0f allocs", depth, afterAllocs, beforeAllocs, scanAllocs)
}

// TestDrainDeclinedOfferIsNotAnAdmission: a waiter that gave up before the
// pass reached it is still popped and scanned (PopNextFresh reaps on age
// only), wins a reservation, and declines the offer. Nothing was placed, so
// the pass is not outcome:admitted and must not lift the heartbeat
// suppression mark: the fleet verdict the mark records has not changed.
// Before the fix admitted was counted before the offer, so the pass read as
// an admission and cleared the mark.
func TestDrainDeclinedOfferIsNotAnAdmission(t *testing.T) {
	reg := New(testLogger())
	sink := newRecordingMetricsSink()
	reg.SetMetricsSink(sink)
	p := drainTestProvider(t, reg, "box", 1000, 1000)
	reg.SetQueue(NewRequestQueue(8, 30*time.Second))
	req := drainTestEnqueue(t, reg, drainTestPending("gone", 800, 1024))
	scans := drainScanCounter(reg)
	drainTestClock(reg)

	reg.Heartbeat(p.ID, drainTestHeartbeat(1000, 1000))
	drainTestExpectScans(t, scans, 1, "saturated heartbeat")
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:heartbeat", "outcome:saturated")
	if !reg.drainSuppress.suppressed(drainTestModel) {
		t.Fatal("model not marked saturated after the heartbeat pass")
	}

	// The waiter gives up, capacity frees, and the idle drain offers it the
	// box anyway; the offer is declined and the reservation released.
	req.markDone()
	drainTestSetBudget(p, 0, 32_768)
	reg.SetProviderIdle(p.ID)
	drainTestExpectScans(t, scans, 1, "idle drain over the departed waiter")
	if got := sink.get("queue.drain.pass", "trigger:idle", "outcome:admitted"); got != 0 {
		t.Fatalf("declined offer counted as an admission: pass{trigger:idle,outcome:admitted} = %d", got)
	}
	if !reg.drainSuppress.suppressed(drainTestModel) {
		t.Fatal("declined offer lifted the heartbeat suppression mark")
	}
	// Scanned, nothing placed, fleet not saturated: the pass is "rejected",
	// not "empty" (which is reserved for passes where no waiter reached a
	// scan).
	expectMetric(t, sink, 1, "queue.drain.pass", "trigger:idle", "outcome:rejected")
	expectMetric(t, sink, 1, "queue.drain.scans", "trigger:idle")
	if n := p.PendingCount(); n != 0 {
		t.Fatalf("pending count after the declined offer = %d, want 0 (reservation released)", n)
	}
	if depth := reg.Queue().QueueSize(drainTestModel); depth != 0 {
		t.Fatalf("queue depth = %d, want 0 (departed waiter not requeued)", depth)
	}
}
