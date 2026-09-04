package registry

// Tests for the warm-pool churn fix: in-flight loads count toward the gap
// (both planners), a failed load stops counting, a hung load is hedged once
// after the bound, load completions no longer extend the demand window, and a
// queue timeout records the live depth. The two promoted measurements
// (TestWarmPoolOneLoadForOneQueuedColdRequest, TestWarmPoolRatchetBounded)
// are the 2026-09-03 overlay tests driven with an injected clock.

import (
	"fmt"
	"testing"
	"time"
)

const inflightModel = "inflight-cold-model"

func inflightFixture(t *testing.T, coldProviders int) (*Registry, *[]modelLoadAction) {
	t.Helper()
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: inflightModel, SizeGB: 15}})
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	for i := 0; i < coldProviders; i++ {
		makeWarmPoolColdProvider(t, reg, fmt.Sprintf("cold-%02d", i), inflightModel, 80, 64, 8)
	}
	return reg, captureWarmPoolLoads(reg)
}

func inflightEnqueue(t *testing.T, reg *Registry) {
	t.Helper()
	req := &QueuedRequest{RequestID: "q", Model: inflightModel, Pending: &PendingRequest{RequestID: "q", Model: inflightModel}}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatal(err)
	}
}

// TestWarmPoolOneLoadForOneQueuedColdRequest (promoted TestC2_DoubleLoad...):
// one request queued for a model no provider has warm, four idle cold boxes.
// The heartbeat/kick planner and the warm-pool tick used to dedup only per
// provider, so this produced 2 immediate load_model sends and one more per
// tick (4 after two ticks). Now the in-flight load closes the gap: 1 send.
func TestWarmPoolOneLoadForOneQueuedColdRequest(t *testing.T) {
	reg, sent := inflightFixture(t, 4)
	cfg := testWarmPoolConfig()
	cfg.QueueAgeThreshold = 0
	reg.ConfigureWarmPool(cfg)

	inflightEnqueue(t, reg)
	reg.RecordWarmPoolQueueEnqueued(inflightModel, 1, 0) // what api.recordWarmPoolQueueState does
	reg.TriggerModelSwaps()                              // api.kickColdDispatch / heartbeat path
	if len(*sent) != 1 {
		t.Fatalf("TriggerModelSwaps sent %d loads, want 1", len(*sent))
	}
	now := time.Now()
	snaps := reg.warmPool.tick(now)
	for _, s := range snaps {
		if s.Model == inflightModel && s.PendingLoads != 1 {
			t.Fatalf("tick snapshot PendingLoads = %d, want 1", s.PendingLoads)
		}
	}
	if len(*sent) != 1 {
		t.Fatalf("warm-pool tick re-issued a load: %d sends, want 1 (%v)", len(*sent), *sent)
	}
	// Further ticks inside the load window issue nothing either.
	for k := 1; k <= 5; k++ {
		reg.warmPool.tick(now.Add(time.Duration(k) * 10 * time.Second))
	}
	if len(*sent) != 1 {
		t.Fatalf("after six ticks: %d sends, want 1 (%v)", len(*sent), *sent)
	}
	// TriggerModelSwaps re-plans the model only once the load has settled.
	reg.TriggerModelSwaps()
	if len(*sent) != 1 {
		t.Fatalf("TriggerModelSwaps re-issued a load for a model with one in flight: %v", *sent)
	}
}

// TestWarmPoolRatchetBounded (promoted TestC2_RatchetSelfSustaining, prod
// values): ONE capacity reject at t=0, 12 idle cold providers, no further
// demand, loads completing 30 s after being sent. Interval 30 s (window 120 s),
// QueueAgeThreshold 5 s, MaxLoadsPerTick 8, BurstBuffer 1. Before: load
// completions refreshed the demand window and every tick re-applied warm+1 to
// a gap that ignored in-flight loads, so the ratchet was self-sustaining and
// all 12 boxes were loaded. After: the demand window closes 120 s after the
// reject regardless of the loads, so the pool is bounded by one reactive
// warm+1 per tick inside the window: 1 + 120/30 = 5 loads, then nothing
// (warm=5 stays). The per-episode reactive floor lands separately and takes
// this to 2 (t=0 floor, t=30 Little's law + burst).
func TestWarmPoolRatchetBounded(t *testing.T) {
	reg, sent := inflightFixture(t, 12)
	cfg := ReadConfig().WarmPool
	cfg.Enabled, cfg.ObserveOnly = true, false
	cfg.Interval = 30 * time.Second
	cfg.QueueAgeThreshold = 5 * time.Second
	cfg.MaxLoadsPerTick = 8
	cfg.MinDwell = 0
	reg.ConfigureWarmPool(cfg)

	t0 := time.Now()
	reg.warmPool.state.recordEvent(inflightModel, warmPoolEventCapacityReject, t0)
	type inflight struct {
		pid  string
		done time.Time
	}
	var pending []inflight
	seen := 0
	trajectory := ""
	for k := 0; k <= 8; k++ { // ticks at t = 0, 30, ..., 240 s
		now := t0.Add(time.Duration(k) * 30 * time.Second)
		var still []inflight
		for _, l := range pending {
			if !now.Before(l.done) {
				reg.MarkModelWarm(l.pid, inflightModel)
				reg.ClearPendingModelLoad(l.pid, inflightModel)
				reg.warmPool.state.recordLoad(inflightModel, true, 30*time.Second, now)
			} else {
				still = append(still, l)
			}
		}
		pending = still
		snaps := reg.warmPool.tick(now)
		for _, a := range (*sent)[seen:] {
			pending = append(pending, inflight{pid: a.providerID, done: now.Add(30 * time.Second)})
		}
		seen = len(*sent)
		for _, s := range snaps {
			if s.Model == inflightModel {
				trajectory += fmt.Sprintf("t=%3ds warm=%d pending=%d target=%d sends=%d cum=%d\n",
					k*30, s.WarmProviders, s.PendingLoads, s.TargetWarm, len(s.Actions), len(*sent))
			}
		}
	}
	t.Log("\n" + trajectory)
	if len(*sent) > 5 {
		t.Fatalf("one capacity reject grew the pool to %d loads over 240 s, want <= 5 (bounded by the closed window):\n%s", len(*sent), trajectory)
	}
	if len(*sent) < 2 {
		t.Fatalf("pool did not reach the Little's-law target: %d loads, want >= 2", len(*sent))
	}
}

// TestWarmPoolLoadCompletionsDoNotExtendPressure: demand counters zero one
// window after the LAST DEMAND EVENT even while loads keep completing; load
// stats age on their own clock.
func TestWarmPoolLoadCompletionsDoNotExtendPressure(t *testing.T) {
	s := newWarmPoolState()
	t0 := time.Now()
	s.recordEvent("m", warmPoolEventCapacityReject, t0)
	s.recordLoad("m", true, 30*time.Second, t0.Add(30*time.Second))
	s.recordLoad("m", true, 30*time.Second, t0.Add(50*time.Second))
	if b := s.snapshot(t0.Add(55*time.Second), time.Minute)["m"]; b.capacityRejects != 1 {
		t.Fatalf("inside the window: capacityRejects = %d, want 1", b.capacityRejects)
	}
	b := s.snapshot(t0.Add(61*time.Second), time.Minute)["m"]
	if b.capacityRejects != 0 {
		t.Fatalf("61 s after the reject: capacityRejects = %d, want 0 despite loads at +30 s and +50 s", b.capacityRejects)
	}
	if b.loadSuccesses != 2 || b.loadDurationEWMA == 0 {
		t.Fatalf("load stats zeroed while loads were recent: successes=%d ewma=%v", b.loadSuccesses, b.loadDurationEWMA)
	}
	b = s.snapshot(t0.Add(111*time.Second), time.Minute)["m"]
	if b.loadSuccesses != 0 || b.loadDurationEWMA != 0 {
		t.Fatalf("load stats not zeroed one window after the last load: successes=%d ewma=%v", b.loadSuccesses, b.loadDurationEWMA)
	}
	if s.loadDurationEWMA("m") != 0 {
		t.Fatal("loadDurationEWMA accessor disagrees with the zeroed bucket")
	}
}

// TestWarmPoolPendingLoadsCloseTheGap: target 2 with 2 loads already in
// flight issues nothing; once those loads settle without warming anything
// (cleared), the same tick issues 2.
func TestWarmPoolPendingLoadsCloseTheGap(t *testing.T) {
	reg, sent := inflightFixture(t, 4)
	cfg := testWarmPoolConfig()
	cfg.MaxLoadsPerTick = 4
	cfg.MinWarmByModel = map[string]int{inflightModel: 2}
	reg.ConfigureWarmPool(cfg)
	now := time.Now()
	reserved := reg.reservePendingModelLoads([]modelLoadAction{
		{providerID: "cold-00", modelID: inflightModel},
		{providerID: "cold-01", modelID: inflightModel},
	}, now)
	if len(reserved) != 2 {
		t.Fatalf("reserved %d, want 2", len(reserved))
	}

	snaps := reg.warmPool.tick(now)
	if len(*sent) != 0 {
		t.Fatalf("tick with 2 loads in flight for a target of 2 sent %v, want none", *sent)
	}
	for _, s := range snaps {
		if s.Model == inflightModel && (s.TargetWarm != 2 || s.PendingLoads != 2) {
			t.Fatalf("snapshot target=%d pending=%d, want 2/2", s.TargetWarm, s.PendingLoads)
		}
	}
	reg.ClearPendingModelLoad("cold-00", inflightModel)
	reg.ClearPendingModelLoad("cold-01", inflightModel)
	reg.warmPool.tick(now.Add(time.Second))
	if len(*sent) != 2 {
		t.Fatalf("tick after the loads settled sent %v, want 2", *sent)
	}
}

// TestSwapPlannerInFlightSkipFailureAndHedge: TriggerModelSwaps plans nothing
// for a model with an unexpired in-flight load; a failed load (start stamp
// dropped, entry re-stamped as a cooldown) frees the model for another box;
// an in-flight load aged past the hedge bound is hedged by exactly one more.
func TestSwapPlannerInFlightSkipFailureAndHedge(t *testing.T) {
	t.Run("failed_load_frees_the_model", func(t *testing.T) {
		reg, sent := inflightFixture(t, 2)
		inflightEnqueue(t, reg)
		reg.TriggerModelSwaps()
		if len(*sent) != 1 {
			t.Fatalf("first plan sent %v, want 1", *sent)
		}
		first := (*sent)[0].providerID
		reg.TriggerModelSwaps()
		if len(*sent) != 1 {
			t.Fatalf("second plan re-issued while a load is in flight: %v", *sent)
		}
		if d := reg.NotePendingModelLoadFailed(first, inflightModel); d <= 0 {
			t.Fatalf("failure duration = %v, want > 0 for a live reservation", d)
		}
		reg.BackoffPendingModelLoadForMemory(first, inflightModel)
		if !hasPendingLoad(reg, first) {
			t.Fatal("cooldown entry missing after the failure backoff")
		}
		if n := reg.inFlightLoadsForModel(inflightModel, time.Now(), pendingLoadHedgeFloor); n != 0 {
			t.Fatalf("cooldown entry counted as in flight: %d", n)
		}
		reg.TriggerModelSwaps()
		if len(*sent) != 2 || (*sent)[1].providerID == first {
			t.Fatalf("plan after the failure sent %v, want one load to the other box", *sent)
		}
	})
	t.Run("hung_load_is_hedged_once", func(t *testing.T) {
		reg, sent := inflightFixture(t, 3)
		inflightEnqueue(t, reg)
		reg.TriggerModelSwaps()
		if len(*sent) != 1 {
			t.Fatalf("first plan sent %v, want 1", *sent)
		}
		first := (*sent)[0].providerID
		// Age the in-flight stamp past the bound; the entry itself is unexpired.
		reg.mu.Lock()
		reg.pendingModelLoadStarted[modelLoadKey{ProviderID: first, ModelID: inflightModel}] = time.Now().Add(-pendingLoadHedgeFloor - time.Second)
		reg.mu.Unlock()
		reg.TriggerModelSwaps()
		if len(*sent) != 2 || (*sent)[1].providerID == first {
			t.Fatalf("aged load was not hedged by one more: %v", *sent)
		}
		reg.TriggerModelSwaps()
		if len(*sent) != 2 {
			t.Fatalf("hedge fanned out beyond one extra load: %v", *sent)
		}
	})
	t.Run("disconnect_clears_and_replans_at_once", func(t *testing.T) {
		reg, sent := inflightFixture(t, 2)
		// Serial-pinned so Disconnect's own drain cannot cold-dispatch the
		// waiter onto the remaining box; the planner path is what is asserted.
		req := &QueuedRequest{RequestID: "q", Model: inflightModel, Pending: &PendingRequest{
			RequestID: "q", Model: inflightModel, AllowedProviderSerials: []string{"serial-elsewhere"}}}
		if err := reg.Queue().Enqueue(req); err != nil {
			t.Fatal(err)
		}
		reg.TriggerModelSwaps()
		first := (*sent)[0].providerID
		reg.TriggerModelSwaps()
		if len(*sent) != 1 {
			t.Fatalf("re-issued while in flight: %v", *sent)
		}
		reg.Disconnect(first)
		reg.TriggerModelSwaps()
		if len(*sent) != 2 || (*sent)[1].providerID == first {
			t.Fatalf("plan after Disconnect(%s) sent %v, want one load to the remaining box", first, *sent)
		}
	})
}

// TestNotePendingModelLoadFailedKeepsCooldownEntry: the failure note drops
// only the in-flight stamp; the provider stays excluded by the per-provider
// dedup for the length of its cooldown.
func TestNotePendingModelLoadFailedKeepsCooldownEntry(t *testing.T) {
	r := New(testLogger())
	now := time.Now()
	r.reservePendingModelLoads([]modelLoadAction{{providerID: "p1", modelID: "m1"}}, now)
	if n := r.inFlightLoadsForModel("m1", now, pendingLoadHedgeFloor); n != 1 {
		t.Fatalf("fresh reservation in flight = %d, want 1", n)
	}
	if d := r.NotePendingModelLoadFailed("p1", "m1"); d < 0 {
		t.Fatalf("duration = %v", d)
	}
	if !hasPendingLoad(r, "p1") {
		t.Fatal("failure note removed the pending entry; the cooldown must survive")
	}
	if n := r.inFlightLoadsForModel("m1", time.Now(), pendingLoadHedgeFloor); n != 0 {
		t.Fatalf("failed load still in flight = %d", n)
	}
	if r.NotePendingModelLoadFailed("p9", "m1") != 0 {
		t.Fatal("unknown pair reported a duration")
	}
	// A backoff without a prior reservation is a cooldown only.
	r.BackoffPendingModelLoadForDrain("p2", "m1")
	if n := r.inFlightLoadsForModel("m1", time.Now(), pendingLoadHedgeFloor); n != 0 {
		t.Fatalf("backoff-only entry counted as in flight: %d", n)
	}
	if !hasPendingLoad(r, "p2") {
		t.Fatal("backoff-only entry not visible to the per-provider dedup")
	}
}

// TestQueueTimeoutRecordsLiveDepth: a queue timeout refreshes the model's
// live queue depth instead of planting Depth=1 — an empty queue leaves no
// queue pressure at all, remaining waiters are counted as they are.
func TestQueueTimeoutRecordsLiveDepth(t *testing.T) {
	reg := New(testLogger())
	reg.ConfigureWarmPool(testWarmPoolConfig())
	reg.SetQueue(NewRequestQueue(16, 30*time.Second))
	reg.RecordWarmPoolQueueEnqueued(inflightModel, 3, 0)
	reg.RecordWarmPoolQueueTimeout(inflightModel, 120*time.Second)
	if q := reg.warmPool.queueSnapshot(time.Now(), time.Minute); len(q) != 0 {
		t.Fatalf("queue timeout on an empty queue left phantom pressure: %+v", q)
	}
	for i := 0; i < 2; i++ {
		id := fmt.Sprintf("w-%d", i)
		if err := reg.Queue().Enqueue(&QueuedRequest{RequestID: id, Model: inflightModel, Pending: &PendingRequest{RequestID: id, Model: inflightModel}}); err != nil {
			t.Fatal(err)
		}
	}
	reg.RecordWarmPoolQueueTimeout(inflightModel, 120*time.Second)
	q := reg.warmPool.queueSnapshot(time.Now(), time.Minute)[inflightModel]
	if q.Depth != 2 {
		t.Fatalf("queue timeout recorded depth %d, want the live 2", q.Depth)
	}
	if q.OldestAge >= 120*time.Second {
		t.Fatalf("queue timeout recorded the timed-out age %v, want the live oldest age", q.OldestAge)
	}
}
