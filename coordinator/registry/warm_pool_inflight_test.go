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
// reject regardless of the loads, and the reactive warm+1 floor applies once
// per demand event: t=0 floor → 1 load; t=30 Little's law (one arrival over
// 30 s × E[S]) + burst → 2; then the gap stays closed and the window closes
// at t=120. Exactly 2 loads (5 with in-flight counting alone, 12 before).
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
	if len(*sent) != 2 {
		t.Fatalf("one capacity reject produced %d loads over 240 s, want exactly 2 (floor once, then Little's law + burst):\n%s", len(*sent), trajectory)
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

// TestWarmPoolReactiveFloorOncePerEpisode: one capacity reject raises the
// target by one on the next tick; later ticks inside the same window do not
// re-apply the floor (they follow Little's law), and a NEW demand event
// re-arms it.
func TestWarmPoolReactiveFloorOncePerEpisode(t *testing.T) {
	reg, sent := inflightFixture(t, 4)
	reg.ConfigureWarmPool(testWarmPoolConfig()) // Interval 1 s → window 60 s, burst 0
	t0 := time.Now()
	reg.warmPool.state.recordEvent(inflightModel, warmPoolEventCapacityReject, t0)

	reg.warmPool.tick(t0)
	if len(*sent) != 1 {
		t.Fatalf("first tick after a reject sent %d loads, want 1 (reactive floor)", len(*sent))
	}
	// The load lands: warm=1, nothing in flight.
	reg.MarkModelWarm((*sent)[0].providerID, inflightModel)
	reg.ClearPendingModelLoad((*sent)[0].providerID, inflightModel)
	reg.warmPool.state.recordLoad(inflightModel, true, 30*time.Second, t0.Add(30*time.Second))
	for k := 31; k <= 50; k += 5 {
		reg.warmPool.tick(t0.Add(time.Duration(k) * time.Second))
	}
	if len(*sent) != 1 {
		t.Fatalf("ticks inside the window re-applied the floor: %d loads, want 1 (%v)", len(*sent), *sent)
	}
	// A new demand event re-arms the floor once more.
	reg.warmPool.state.recordEvent(inflightModel, warmPoolEventCapacityReject, t0.Add(55*time.Second))
	reg.warmPool.tick(t0.Add(56 * time.Second))
	if len(*sent) != 2 {
		t.Fatalf("new demand event did not re-arm the floor: %d loads, want 2", len(*sent))
	}
	reg.warmPool.tick(t0.Add(57 * time.Second))
	if len(*sent) != 2 {
		t.Fatalf("floor re-applied without a new event: %d loads, want 2", len(*sent))
	}
}

// TestWarmPoolSustainedPressureConvergesThenStops: rejects keep arriving
// (one per tick) only while the pool is short of the capacity the demand
// needs — three warm boxes here — so the pool grows one per tick under the
// re-armed floor, then stops once the rejects do; no further loads follow.
func TestWarmPoolSustainedPressureConvergesThenStops(t *testing.T) {
	reg, sent := inflightFixture(t, 8)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	const needWarm = 3
	t0 := time.Now()
	warm := 0
	for k := 0; k < 12; k++ {
		now := t0.Add(time.Duration(k) * 10 * time.Second)
		if warm < needWarm {
			reg.warmPool.state.recordEvent(inflightModel, warmPoolEventCapacityReject, now)
		}
		before := len(*sent)
		reg.warmPool.tick(now)
		// Loads land before the next tick.
		for _, a := range (*sent)[before:] {
			reg.MarkModelWarm(a.providerID, inflightModel)
			reg.ClearPendingModelLoad(a.providerID, inflightModel)
			reg.warmPool.state.recordLoad(inflightModel, true, 5*time.Second, now.Add(5*time.Second))
			warm++
		}
		if warm >= needWarm && len(*sent) > needWarm+1 {
			t.Fatalf("tick %d: pool kept growing after the rejects stopped: %d loads (warm %d)", k, len(*sent), warm)
		}
	}
	if warm < needWarm {
		t.Fatalf("pool never reached the needed capacity: warm=%d", warm)
	}
	if len(*sent) > needWarm+1 {
		t.Fatalf("pool overshot: %d loads for a demand of %d warm (+1 tolerance)", len(*sent), needWarm)
	}
}

// reactiveAppliedAtFor reads the model's reactiveAppliedAt stamp (zero when
// the floor has never been consumed).
func reactiveAppliedAtFor(reg *Registry, model string) time.Time {
	s := reg.warmPool.state
	s.mu.Lock()
	defer s.mu.Unlock()
	if b := s.models[model]; b != nil {
		return b.reactiveAppliedAt
	}
	return time.Time{}
}

// TestWarmPoolReactiveFloorSurvivesUnpressuredTick: the reactive warm+1 arm
// is consumed only by a tick that evaluated it, i.e. one under demand
// pressure (warmTarget returns the current warm count before reading the
// floor otherwise). A waiter enters the queue from the dispatch loop (queue
// state only — no demand event), the warm box still reports headroom, so the
// trigger-driven tick sees no pressure and must leave the arm intact; when
// the box's next heartbeat reports its slot busy, the warm set is saturated
// under external pressure and the first pressured tick applies the floor.
// Before the fix the unpressured tick stamped reactiveAppliedAt, the
// pressured tick found no arm, and Little's law (L = 2 at qc >= 2) kept the
// target at the current warm count: no load for the waiter.
func TestWarmPoolReactiveFloorSurvivesUnpressuredTick(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-floor-unpressured"
	warm := makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].MaxConcurrency = 4
	warm.mu.Unlock()
	reg.ConfigureWarmPool(testWarmPoolConfig()) // QueueAgeThreshold 2 s, burst 0
	sent := captureWarmPoolLoads(reg)

	t0 := time.Now()
	reg.warmPool.recordQueuePressure(model, 1, 0, t0) // api.recordWarmPoolQueueState
	reg.warmPool.tick(t0)
	if len(*sent) != 0 {
		t.Fatalf("unpressured tick sent %d loads, want 0", len(*sent))
	}
	if at := reactiveAppliedAtFor(reg, model); !at.IsZero() {
		t.Fatalf("unpressured tick consumed the reactive floor arm: reactiveAppliedAt = %v, want zero", at)
	}

	// Next heartbeat: the warm box's slot is busy. Saturated warm set under
	// external pressure (the waiter) -> demand pressure with no new event.
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].NumRunning = 1
	warm.mu.Unlock()
	t1 := t0.Add(time.Second)
	reg.warmPool.tick(t1)
	if len(*sent) != 1 {
		t.Fatalf("first pressured tick sent %d loads, want 1 (reactive floor armed by the queued waiter)", len(*sent))
	}
	if at := reactiveAppliedAtFor(reg, model); !at.Equal(t1) {
		t.Fatalf("pressured tick did not consume the arm: reactiveAppliedAt = %v, want %v", at, t1)
	}
}

// TestWarmPoolInFlightLoadsAreReachable: a box with a load in flight is
// excluded from eligibleCold (warmColdPendingLoad) but WILL be warm shortly,
// so it counts toward what the fleet can reach. Three cold boxes, a floor of
// 3 and one load already in flight: the target is 3 and the tick issues the
// two remaining loads. Before the fix the target was clamped to
// warm + eligibleCold = 2 and the gap then subtracted the in-flight load a
// second time (min(T-W-I, E-I) instead of min(T-W-I, E)): one load, and the
// third box waited a full load latency for the first two to land.
func TestWarmPoolInFlightLoadsAreReachable(t *testing.T) {
	reg, sent := inflightFixture(t, 3)
	cfg := testWarmPoolConfig()
	cfg.MaxLoadsPerTick = 4
	cfg.MinWarmByModel = map[string]int{inflightModel: 3}
	reg.ConfigureWarmPool(cfg)
	now := time.Now()
	if got := reg.reservePendingModelLoads([]modelLoadAction{{providerID: "cold-00", modelID: inflightModel}}, now); len(got) != 1 {
		t.Fatalf("reserved %d, want 1", len(got))
	}

	snaps := reg.warmPool.tick(now)
	var snap WarmPoolSnapshot
	for _, s := range snaps {
		if s.Model == inflightModel {
			snap = s
		}
	}
	if snap.PendingLoads != 1 || snap.EligibleCold != 2 {
		t.Fatalf("snapshot pending=%d eligible=%d, want 1/2", snap.PendingLoads, snap.EligibleCold)
	}
	if snap.TargetWarm != 3 {
		t.Fatalf("TargetWarm = %d, want 3 (warm 0 + in flight 1 + eligible cold 2 are all reachable)", snap.TargetWarm)
	}
	if len(*sent) != 2 {
		t.Fatalf("tick sent %d loads, want 2 (%v)", len(*sent), *sent)
	}
	for _, a := range *sent {
		if a.providerID == "cold-00" {
			t.Fatalf("tick re-issued the in-flight load: %v", *sent)
		}
	}
}

// TestTargetWarmClampsCountInFlightLoads: the controller-side bounds on the
// target (the MinDwell hold, the MinWarmByModel floor and the dedicated
// whole-pool rule) use the same reachable set as warmTarget — warm + in
// flight + eligible cold — so none of them re-introduces the double count.
func TestTargetWarmClampsCountInFlightLoads(t *testing.T) {
	reg := New(testLogger())
	reg.SetDedicatedModels([]string{"gemma-4"})
	cfg := testWarmPoolConfig()
	cfg.MinDwell = time.Minute
	cfg.MinWarmByModel = map[string]int{qwenBuild: 4}
	c := newWarmPoolController(reg, cfg)
	params := c.targetParams()
	now := time.Now()
	two := []warmPoolCandidate{{providerID: "c1"}, {providerID: "c2"}}

	// Dwell hold: the last target (5) is held but bounded by the reachable
	// set 0 + 1 + 2 = 3, not by warm + eligibleCold = 2.
	held := warmPoolPressureBucket{lastTarget: 5, lastTargetChangedAt: now}
	fleet := warmPoolModelSnapshot{model: "plain", eligibleCold: two}
	in := c.targetInputs(fleet, held, warmPoolQueuePressure{}, 1)
	if got := c.targetWarm(fleet, held, in, params, time.Second, now); got != 3 {
		t.Fatalf("dwell-held target = %d, want 3 (warm 0 + in flight 1 + eligible 2)", got)
	}
	// MinWarmByModel floor (4) bounded the same way.
	floored := warmPoolModelSnapshot{model: qwenBuild, eligibleCold: two}
	in = c.targetInputs(floored, warmPoolPressureBucket{}, warmPoolQueuePressure{}, 1)
	if got := c.targetWarm(floored, warmPoolPressureBucket{}, in, params, time.Second, now); got != 3 {
		t.Fatalf("floored target = %d, want 3 (warm 0 + in flight 1 + eligible 2)", got)
	}
	// Dedicated pool under demand: the WHOLE pool includes the in-flight box.
	dedicated := warmPoolModelSnapshot{model: gemmaBuild, warm: 2, eligibleCold: two}
	demand := warmPoolPressureBucket{capacityRejects: 1}
	in = c.targetInputs(dedicated, demand, warmPoolQueuePressure{}, 1)
	if got := c.targetWarm(dedicated, demand, in, params, time.Second, now); got != 5 {
		t.Fatalf("dedicated whole-pool target = %d, want 5 (warm 2 + in flight 1 + eligible 2)", got)
	}
}
