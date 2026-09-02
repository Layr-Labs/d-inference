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
// configured as a fleet-wide constant — see headroomProviders.

import (
	"testing"
	"time"
)

// derivedParams: floor comes from the measured ramp, no operator override.
func derivedParams(maxProviders int, windows float64) warmTargetParams {
	return warmTargetParams{
		DecodeFloorTPS:             15,
		LoadFactorK:                effectiveTPSLoadFactor,
		BurstBuffer:                0,
		HeadroomEnabledParams:      true,
		HeadroomMaxProviders:       maxProviders,
		HeadroomLoadWindows:        windows,
		FallbackQualityConcurrency: 4,
		AssumedPromptTokens:        512,
		AssumedCompletionTokens:    256,
		MinServiceTime:             warmPoolMinServiceTime,
		MaxServiceTime:             warmPoolMaxServiceTime,
	}
}

// overrideParams: an explicit per-model pin.
func overrideParams(m map[string]int) warmTargetParams {
	p := derivedParams(64, 1)
	p.HeadroomProviders = m
	return p
}

// The pool grows on MEASURED demand growth with NO pressure signal at all.
// Pre-fix this returned in.Warm unchanged (nothing warmed until a request failed).
func TestHeadroomWarmsWithoutAnyPressureSignal(t *testing.T) {
	p := derivedParams(64, 1)
	in := warmTargetInputs{
		Model: "m", Warm: 5, WarmSaturated: 0, EligibleCold: 50,
		RunningRequests: 0, OccupancyRamp: 40, // 40 slots/interval of growth
		SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	// qc=7 -> ceil(40/7)=6 providers of headroom; occupied 0 -> target 6.
	if got := warmTarget(in, p, time.Second); got != 6 {
		t.Fatalf("warmTarget = %d, want 6 (derived floor, zero pressure)", got)
	}
}

// A model with no measured ramp gets NO proactive warming — the conservative
// direction. This is what keeps a brand-new build from being warmed on a guess.
func TestHeadroomNoRampNoProactiveWarming(t *testing.T) {
	p := derivedParams(64, 1)
	in := warmTargetInputs{
		Model: "m", Warm: 5, EligibleCold: 50, RunningRequests: 0,
		OccupancyRamp: 0, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 5 {
		t.Fatalf("warmTarget = %d, want 5 (no ramp measured -> stay put)", got)
	}
}

// The derived floor scales with each model's OWN ramp: this is the property a
// flat fleet-wide constant cannot have.
func TestHeadroomScalesPerModelWithRamp(t *testing.T) {
	p := derivedParams(64, 1)
	// qc=7 for all rows; only the measured ramp differs.
	for _, tc := range []struct{ ramp, want int }{
		{2, 1},    // ceil(2/7)=1
		{13, 2},   // ceil(13/7)=2
		{33, 5},   // ceil(33/7)=5
		{100, 15}, // ceil(100/7)=15
	} {
		in := warmTargetInputs{
			Model: "m", Warm: 1, EligibleCold: 500, RunningRequests: 0,
			OccupancyRamp: float64(tc.ramp), SoloDecodeTPS: 60, MaxProviderConc: 8,
			DemandPressure: false,
		}
		if got := warmTarget(in, p, time.Second); got != tc.want {
			t.Errorf("ramp=%d: warmTarget = %d, want %d", tc.ramp, got, tc.want)
		}
	}
}

// An explicit per-model override wins over the derived value, and applies only to
// the named model.
func TestHeadroomPerModelOverride(t *testing.T) {
	p := overrideParams(map[string]int{"pinned": 20})
	base := warmTargetInputs{
		Warm: 1, EligibleCold: 500, RunningRequests: 0,
		OccupancyRamp: 7, // would derive ceil(7/7)=1
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	pinned := base
	pinned.Model = "pinned"
	if got := warmTarget(pinned, p, time.Second); got != 20 {
		t.Fatalf("pinned model: warmTarget = %d, want 20 (override)", got)
	}
	other := base
	other.Model = "other"
	if got := warmTarget(other, p, time.Second); got != 1 {
		t.Fatalf("unpinned model: warmTarget = %d, want 1 (derived)", got)
	}
}

// The derived floor is capped so a pathological ramp cannot demand the fleet.
// An operator override is NOT capped — naming a number means it.
func TestHeadroomMaxProvidersCapsDerivedNotOverride(t *testing.T) {
	in := warmTargetInputs{
		Model: "m", Warm: 1, EligibleCold: 5000, RunningRequests: 0,
		OccupancyRamp: 7000, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	// derived would be ceil(7000/7)=1000, capped to 10
	if got := warmTarget(in, derivedParams(10, 1), time.Second); got != 10 {
		t.Fatalf("derived: warmTarget = %d, want 10 (capped)", got)
	}
	p := overrideParams(map[string]int{"m": 900})
	p.HeadroomMaxProviders = 10
	if got := warmTarget(in, p, time.Second); got != 900 {
		t.Fatalf("override: warmTarget = %d, want 900 (uncapped)", got)
	}
}

// LoadWindows scales the floor by how long a cold load takes.
func TestHeadroomLoadWindowsScalesFloor(t *testing.T) {
	in := warmTargetInputs{
		Model: "m", Warm: 1, EligibleCold: 500, RunningRequests: 0,
		OccupancyRamp: 14, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	// qc=7: 1 window -> ceil(14/7)=2 ; 2 windows -> ceil(28/7)=4
	if got := warmTarget(in, derivedParams(64, 1), time.Second); got != 2 {
		t.Fatalf("1 window: warmTarget = %d, want 2", got)
	}
	if got := warmTarget(in, derivedParams(64, 2), time.Second); got != 4 {
		t.Fatalf("2 windows: warmTarget = %d, want 4", got)
	}
}

// Headroom is expressed in CAPACITY, so a saturated provider is accounted for by
// the requests occupying it, NOT by adding WarmSaturated to the floor — that
// double-counts, since its capacity is already inside warm*qc.
func TestHeadroomDoesNotDoubleCountSaturated(t *testing.T) {
	p := derivedParams(64, 1)
	base := warmTargetInputs{
		Model: "m", Warm: 20, EligibleCold: 50, RunningRequests: 40,
		OccupancyRamp: 70, // ceil(70/7)=10 providers of headroom
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	// ceil(40/7)=6 + 10 = 16, below warm=20 -> stays 20, whatever saturated says.
	for _, sat := range []int{0, 5, 15, 20} {
		in := base
		in.WarmSaturated = sat
		if got := warmTarget(in, p, time.Second); got != 20 {
			t.Errorf("saturated=%d: warmTarget = %d, want 20 (occupancy is what counts)", sat, got)
		}
	}
	// Fully-busy pool: occupied == warm*qc = 140. ceil(140/7)=20 + 10 = 30,
	// NOT 30+20 (the double-counted value the first implementation produced).
	busy := base
	busy.RunningRequests = 140
	busy.WarmSaturated = 20
	if got := warmTarget(busy, p, time.Second); got != 30 {
		t.Fatalf("warmTarget(fully busy) = %d, want 30 (no saturated double-count)", got)
	}
}

// In-flight load consumes capacity, so the floor rises with occupancy.
// qc=7: floor((60/15 - 1)/0.39) = 7.69 -> 7.
func TestHeadroomTracksOccupancy(t *testing.T) {
	p := derivedParams(64, 1)
	for _, tc := range []struct{ running, want int }{
		{0, 10},    // ceil(0/7)  + 10
		{8, 12},    // ceil(8/7)=2  +10
		{80, 22},   // ceil(80/7)=12 +10
		{800, 125}, // ceil(800/7)=115 +10
	} {
		in := warmTargetInputs{
			Model: "m", Warm: 1, WarmSaturated: 0, EligibleCold: 5000,
			RunningRequests: tc.running, OccupancyRamp: 70, // -> 10 providers
			SoloDecodeTPS: 60, MaxProviderConc: 8,
			DemandPressure: false,
		}
		if got := warmTarget(in, p, time.Second); got != tc.want {
			t.Errorf("running=%d: warmTarget = %d, want %d", tc.running, got, tc.want)
		}
	}
}

// A pool already far larger than its load does NOT grow on the headroom floor —
// the floor is about spare capacity, not pool size.
func TestHeadroomIdleOversizedPoolOnlyNudges(t *testing.T) {
	p := derivedParams(64, 1)
	p.BurstBuffer = 1
	in := warmTargetInputs{
		Model: "m", Warm: 300, WarmSaturated: 300, EligibleCold: 200,
		RunningRequests: 600, OccupancyRamp: 175, // ceil(175/7)=25
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: true,
	}
	// ceil(600/7)=86 + 25 = 111, well below warm=300 -> reactive nudge only.
	if got := warmTarget(in, p, time.Second); got != in.Warm+1 {
		t.Fatalf("warmTarget = %d, want %d (reactive nudge only)", got, in.Warm+1)
	}
}

// A shortfall exceeding the current pool closes in ONE tick, not +1 per interval.
func TestHeadroomClosesShortfallExceedingPoolInOneTick(t *testing.T) {
	p := derivedParams(64, 1)
	p.BurstBuffer = 1
	in := warmTargetInputs{
		Model: "m", Warm: 100, WarmSaturated: 100, EligibleCold: 400,
		RunningRequests: 2100, OccupancyRamp: 175, // ceil(175/7)=25
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: true,
	}
	// ceil(2100/7)=300 + 25 = 325, far above warm+1=101.
	got := warmTarget(in, p, time.Second)
	if got != 325 {
		t.Fatalf("warmTarget = %d, want 325", got)
	}
	if got <= in.Warm+1 {
		t.Fatalf("target %d did not beat the +1/tick reactive floor", got)
	}
}

// The floor never demands hardware that does not exist.
func TestHeadroomCappedByReachable(t *testing.T) {
	p := derivedParams(64, 1)
	in := warmTargetInputs{
		Model: "m", Warm: 5, WarmSaturated: 5, EligibleCold: 3,
		RunningRequests: 0, OccupancyRamp: 700, // would want 100 providers
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 8 {
		t.Fatalf("warmTarget = %d, want 8 (warm+eligibleCold ceiling)", got)
	}
}

// Disabling restores the exact pre-fix reactive behaviour.
func TestHeadroomDisabledIsOptOut(t *testing.T) {
	p := derivedParams(64, 1)
	p.HeadroomEnabledParams = false
	p.BurstBuffer = 1
	in := warmTargetInputs{
		Model: "m", Warm: 5, WarmSaturated: 5, EligibleCold: 50,
		RunningRequests: 0, OccupancyRamp: 700,
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 5 {
		t.Fatalf("warmTarget = %d, want 5 (headroom disabled, no pressure)", got)
	}
	withPressure := in
	withPressure.DemandPressure = true
	if got := warmTarget(withPressure, p, time.Second); got != 6 {
		t.Fatalf("warmTarget = %d, want 6 (reactive nudge preserved)", got)
	}
}

// The pool must never SHRINK as a result of this change.
func TestHeadroomNeverShrinksPool(t *testing.T) {
	p := derivedParams(64, 1)
	in := warmTargetInputs{
		Model: "m", Warm: 500, WarmSaturated: 0, EligibleCold: 0,
		RunningRequests: 0, OccupancyRamp: 7,
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 500 {
		t.Fatalf("warmTarget = %d, want 500 (never shrink below current warm)", got)
	}
}

// foldOccupancyRamp: only INCREASES are folded, so a draining spike does not
// shrink headroom right when the next spike is most likely.
func TestFoldOccupancyRampIgnoresDecreases(t *testing.T) {
	s := newWarmPoolState()
	// first observation only seeds the baseline
	s.foldOccupancyRamp(map[string]int{"m": 100}, 1.0)
	if got := s.models["m"].occupancyRampEWMA; got != 0 {
		t.Fatalf("after seed, ramp = %v, want 0", got)
	}
	// +50 rise, alpha=1 -> ramp == 50
	s.foldOccupancyRamp(map[string]int{"m": 150}, 1.0)
	if got := s.models["m"].occupancyRampEWMA; got != 50 {
		t.Fatalf("after +50, ramp = %v, want 50", got)
	}
	// big DROP must fold as 0, not negative
	s.foldOccupancyRamp(map[string]int{"m": 10}, 1.0)
	if got := s.models["m"].occupancyRampEWMA; got != 0 {
		t.Fatalf("after drop, ramp = %v, want 0 (floored, not negative)", got)
	}
	if got := s.models["m"].lastOccupancy; got != 10 {
		t.Fatalf("lastOccupancy = %d, want 10 (baseline still tracks the drop)", got)
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
	reg.warmPool.tick(time.Now())
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].Model = model
	warm.BackendCapacity.Slots[0].State = "running"
	warm.BackendCapacity.Slots[0].NumRunning = 20
	warm.mu.Unlock()
	snaps := reg.warmPool.tick(time.Now())

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
