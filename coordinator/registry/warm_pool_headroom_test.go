package registry

// warm_pool_headroom_test.go — proactive headroom warming.
//
// Guards the 2026-09-01 defect: the controller could only grow the warm pool
// AFTER a demand-pressure signal (capacity_reject / ttft_miss / cold_dispatch),
// each of which means a request had already been shed or delayed, and the
// reactive floor then capped growth at +1 provider per control interval (30s in
// prod) regardless of shortfall size. The pool was therefore smallest exactly
// when load was rising.

import (
	"testing"
	"time"
)

func headroomParams(headroom, burst int) warmTargetParams {
	return warmTargetParams{
		DecodeFloorTPS:             15,
		LoadFactorK:                effectiveTPSLoadFactor,
		BurstBuffer:                burst,
		HeadroomProviders:          headroom,
		FallbackQualityConcurrency: 4,
		AssumedPromptTokens:        512,
		AssumedCompletionTokens:    256,
		MinServiceTime:             warmPoolMinServiceTime,
		MaxServiceTime:             warmPoolMaxServiceTime,
	}
}

// The pool grows toward the headroom floor with NO pressure signal at all.
// Pre-fix this returned in.Warm unchanged (nothing warmed until a request failed).
func TestHeadroomWarmsWithoutAnyPressureSignal(t *testing.T) {
	p := headroomParams(10, 1)
	in := warmTargetInputs{
		Warm: 5, WarmSaturated: 0, EligibleCold: 50,
		RunningRequests: 0, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	got := warmTarget(in, p, time.Second)
	if got != 10 {
		t.Fatalf("warmTarget = %d, want 10 (headroom floor, zero pressure)", got)
	}
}

// Headroom is expressed in CAPACITY, so a saturated provider is accounted for by
// the requests occupying it (in RunningRequests), NOT by adding WarmSaturated to
// the floor — doing that double-counts, since its capacity is already inside
// warm*qc. Same occupancy => same target regardless of the saturated count.
func TestHeadroomDoesNotDoubleCountSaturated(t *testing.T) {
	p := headroomParams(10, 0)
	base := warmTargetInputs{
		Warm: 20, EligibleCold: 50, RunningRequests: 40,
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	// qc=7 -> ceil(40/7)=6, +10 headroom = 16, below warm=20 so target stays 20.
	for _, sat := range []int{0, 5, 15, 20} {
		in := base
		in.WarmSaturated = sat
		if got := warmTarget(in, p, time.Second); got != 20 {
			t.Errorf("saturated=%d: warmTarget = %d, want 20 (occupancy is what counts)", sat, got)
		}
	}
	// Fully-busy pool: occupied == warm*qc. Required warm is ceil(140/7)+10 = 30,
	// NOT 30+20 (the double-counted value the first implementation produced).
	busy := base
	busy.RunningRequests = 140
	busy.WarmSaturated = 20
	if got := warmTarget(busy, p, time.Second); got != 30 {
		t.Fatalf("warmTarget(fully busy) = %d, want 30 (no saturated double-count)", got)
	}
}

// In-flight load consumes capacity, so the floor rises with occupancy even
// though no request has failed. qc here is 7, not the provider cap of 8:
// floor((60/15 - 1)/0.39) = 7.69 -> 7.
func TestHeadroomTracksOccupancy(t *testing.T) {
	p := headroomParams(10, 0)
	for _, tc := range []struct{ running, want int }{
		{0, 10},    // ceil(0/7)+10
		{8, 12},    // ceil(8/7)=2  +10
		{80, 22},   // ceil(80/7)=12 +10
		{800, 125}, // ceil(800/7)=115 +10
	} {
		in := warmTargetInputs{
			Warm: 1, WarmSaturated: 0, EligibleCold: 5000,
			RunningRequests: tc.running, SoloDecodeTPS: 60, MaxProviderConc: 8,
			DemandPressure: false,
		}
		if got := warmTarget(in, p, time.Second); got != tc.want {
			t.Errorf("running=%d: warmTarget = %d, want %d", tc.running, got, tc.want)
		}
	}
}

// A pool already far larger than its load does NOT grow on the headroom floor —
// the floor is about spare capacity, not pool size. With warm=300 carrying only
// 600 requests at qc=7, capacity is 2100 and the floor (111) is already met, so
// only the reactive nudge applies.
func TestHeadroomIdleOversizedPoolOnlyNudges(t *testing.T) {
	p := headroomParams(25, 1)
	in := warmTargetInputs{
		Warm: 300, WarmSaturated: 300, EligibleCold: 200,
		RunningRequests: 600, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: true,
	}
	// qc=7 -> ceil(600/7)=86 +25 headroom = 111, well below warm=300.
	if got := warmTarget(in, p, time.Second); got != in.Warm+1 {
		t.Fatalf("warmTarget = %d, want %d (reactive nudge only)", got, in.Warm+1)
	}
}

// A shortfall large enough to exceed the current pool closes in ONE tick rather
// than crawling at +1 per interval.
func TestHeadroomClosesShortfallExceedingPoolInOneTick(t *testing.T) {
	p := headroomParams(25, 1)
	in := warmTargetInputs{
		Warm: 100, WarmSaturated: 100, EligibleCold: 400,
		RunningRequests: 2100, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: true,
	}
	// qc=7 -> ceil(2100/7)=300, +25 = 325, far above warm+1=101.
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
	p := headroomParams(100, 0)
	in := warmTargetInputs{
		Warm: 5, WarmSaturated: 5, EligibleCold: 3,
		RunningRequests: 0, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 8 {
		t.Fatalf("warmTarget = %d, want 8 (warm+eligibleCold ceiling)", got)
	}
}

// HeadroomProviders=0 restores the exact pre-fix reactive behaviour, so the
// change is opt-in and instantly revertible by config.
func TestHeadroomZeroIsOptOut(t *testing.T) {
	p := headroomParams(0, 1)
	in := warmTargetInputs{
		Warm: 5, WarmSaturated: 5, EligibleCold: 50,
		RunningRequests: 0, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 5 {
		t.Fatalf("warmTarget = %d, want 5 (headroom disabled, no pressure)", got)
	}
	// And with pressure it still nudges +1, exactly as before.
	withPressure := in
	withPressure.DemandPressure = true
	if got := warmTarget(withPressure, p, time.Second); got != 6 {
		t.Fatalf("warmTarget = %d, want 6 (reactive nudge preserved)", got)
	}
}

// The pool must never SHRINK as a result of this change; dwell/scale-down
// remains the caller's business.
func TestHeadroomNeverShrinksPool(t *testing.T) {
	p := headroomParams(2, 0)
	in := warmTargetInputs{
		Warm: 500, WarmSaturated: 0, EligibleCold: 0,
		RunningRequests: 0, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 500 {
		t.Fatalf("warmTarget = %d, want 500 (never shrink below current warm)", got)
	}
}

// End-to-end through the controller: a fleet with idle cold boxes and NO
// pressure events issues proactive model loads.
func TestControllerWarmsProactivelyWithoutPressure(t *testing.T) {
	reg := New(testLogger())
	model := "headroom-e2e"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	for _, id := range []string{"cold-a", "cold-b", "cold-c"} {
		makeWarmPoolColdProvider(t, reg, id, model, 80, 64, 8)
	}
	cfg := testWarmPoolConfig()
	cfg.HeadroomProviders = 3
	cfg.MaxLoadsPerTick = 2
	cfg.MaxLoadsPerTickCeiling = 2
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	snaps := reg.warmPool.tick(time.Now())

	if len(snaps) != 1 {
		t.Fatalf("snapshots = %d, want 1", len(snaps))
	}
	if snaps[0].TargetWarm != 3 {
		t.Fatalf("TargetWarm = %d, want 3 (headroom floor)", snaps[0].TargetWarm)
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
