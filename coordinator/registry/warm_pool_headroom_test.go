package registry

// warm_pool_headroom_test.go — proactive headroom warming.
//
// Guards the 2026-09-01 defect: the controller could only grow the warm pool
// AFTER a demand-pressure signal (capacity_reject / ttft_miss / cold_dispatch),
// each of which means a request had already been shed or delayed, and the
// reactive floor then capped growth at +1 provider per control interval (30s in
// prod) regardless of shortfall size. The pool was therefore smallest exactly
// when load was rising.
//
// The floor is DERIVED per model from measured demand growth (OccupancyRamp), not
// configured as a fleet-wide constant — see warmpool.HeadroomProviders.

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// A no-pressure fleet whose warm providers are ALL blocked by a co-resident model
// must issue loads end-to-end through the controller. This is the shape that
// produced no actions at all pre-fix.
//
// The pool is deliberately sized so the foreign-blocked term is the DECIDING one:
// several warm providers against a small measured ramp, so ceil(occupied/qc) +
// headroom lands BELOW warm and only the blocked count lifts the target above it.
// With one warm provider the derived headroom alone clears the bar and the test
// would pass against the unfixed formula, asserting nothing.
func TestControllerWarmsWhenWarmPoolIsForeignBlocked(t *testing.T) {
	reg := New(testLogger())
	model := "foreign-blocked-e2e"
	other := "co-resident-model"
	warmProviders := []*Provider{
		makeSchedulerProvider(t, reg, "warm-a", model, 80),
		makeSchedulerProvider(t, reg, "warm-b", model, 80),
		makeSchedulerProvider(t, reg, "warm-c", model, 80),
	}
	for _, id := range []string{"cold-a", "cold-b", "cold-c"} {
		makeWarmPoolColdProvider(t, reg, id, model, 80, 64, 8)
	}
	cfg := testWarmPoolConfig()
	cfg.HeadroomEnabled = true
	cfg.HeadroomMaxProviders = 64
	cfg.HeadroomLoadWindows = 1
	cfg.MaxLoadsPerTick = 3
	cfg.MaxLoadsPerTickCeiling = 3
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	// Seed the occupancy baseline, then a SMALL rise so a modest ramp is measured.
	t0 := time.Now()
	reg.warmPool.Tick(t0)
	warmProviders[0].mu.Lock()
	warmProviders[0].BackendCapacity.Slots[0].NumRunning = 1
	warmProviders[0].mu.Unlock()
	reg.warmPool.Tick(t0.Add(cfg.Interval))

	// Now every warm box's capacity is consumed by a DIFFERENT resident model.
	// This model's slots report zero load, so that traffic is invisible in
	// `occupied` while each box still contributes qc to nominal warm capacity.
	for _, p := range warmProviders {
		p.mu.Lock()
		p.BackendCapacity.Slots[0].NumRunning = 0
		p.BackendCapacity.Slots[0].NumWaiting = 0
		p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
			Model: other, State: "running", NumRunning: 64, MaxConcurrency: 1,
		})
		p.mu.Unlock()
	}
	*sent = nil
	snaps := reg.warmPool.Tick(t0.Add(2 * cfg.Interval))

	var snap *WarmPoolSnapshot
	for i := range snaps {
		if snaps[i].Model == model {
			snap = &snaps[i]
		}
	}
	if snap == nil {
		t.Fatalf("no snapshot for %q in %+v", model, snaps)
	}
	if snap.WarmForeignBlocked != len(warmProviders) {
		t.Fatalf("WarmForeignBlocked = %d, want %d (all warm boxes saturated by %q with no load of their own)",
			snap.WarmForeignBlocked, len(warmProviders), other)
	}
	// Guard that the foreign term is what decides it: without it the floor is
	// ceil(occupied/qc)+headroom, which must be at or below warm here.
	if unfixed := snap.HeadroomProviders + snap.RunningRequests + snap.WaitingRequests + snap.QueueDepth; unfixed > snap.WarmProviders {
		t.Fatalf("test does not isolate the fix: unfixed floor bound %d already exceeds warm %d",
			unfixed, snap.WarmProviders)
	}
	if snap.TargetWarm <= snap.WarmProviders {
		t.Fatalf("target_warm=%d warm=%d: no growth despite every warm provider being unusable",
			snap.TargetWarm, snap.WarmProviders)
	}
	if len(*sent) == 0 {
		t.Fatal("no loads issued while the entire warm pool was blocked by a co-resident model")
	}
}

// End-to-end through the controller: a fleet with idle cold boxes and NO pressure
// events issues proactive loads once a ramp has been measured.
func TestControllerWarmsProactivelyWithoutPressure(t *testing.T) {
	reg := New(testLogger())
	model := "headroom-e2e"
	warm := makeSchedulerProvider(t, reg, "warm", model, 80)
	for _, id := range []string{"cold-a", "cold-b", "cold-c"} {
		makeWarmPoolColdProvider(t, reg, id, model, 80, 64, 8)
	}
	cfg := testWarmPoolConfig()
	cfg.HeadroomEnabled = true
	cfg.HeadroomMaxProviders = 64
	cfg.HeadroomLoadWindows = 1
	cfg.MaxLoadsPerTick = 2
	cfg.MaxLoadsPerTickCeiling = 2
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	// Tick once at zero load to seed the occupancy baseline, then raise occupancy
	// so the controller MEASURES a ramp (no pressure events recorded at all).
	// The second tick must be a full control interval later: foldOccupancyRamp
	// gates on half the interval so coalesced hot-path triggers cannot fragment
	// one interval's growth into understated samples.
	t0 := time.Now()
	reg.warmPool.Tick(t0)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].Model = model
	warm.BackendCapacity.Slots[0].State = "running"
	warm.BackendCapacity.Slots[0].NumRunning = 20
	warm.mu.Unlock()
	snaps := reg.warmPool.Tick(t0.Add(cfg.Interval))

	var snap *WarmPoolSnapshot
	for i := range snaps {
		if snaps[i].Model == model {
			snap = &snaps[i]
		}
	}
	if snap == nil {
		t.Fatalf("no snapshot for %q in %+v", model, snaps)
	}
	if snap.OccupancyRamp <= 0 {
		t.Fatalf("OccupancyRamp = %v, want > 0 (ramp must be measured)", snap.OccupancyRamp)
	}
	if snap.HeadroomProviders <= 0 {
		t.Fatalf("HeadroomProviders = %d, want > 0 (derived from the ramp)", snap.HeadroomProviders)
	}
	if len(*sent) == 0 {
		t.Fatal("no proactive loads issued with zero pressure events")
	}
	for _, a := range *sent {
		if a.modelID != model {
			t.Fatalf("load for %q, want %q", a.modelID, model)
		}
	}
}
