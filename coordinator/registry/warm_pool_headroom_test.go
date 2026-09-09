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

	"github.com/eigeninference/d-inference/coordinator/protocol"
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
//
// interval/minInterval are 0 here, which disables the elapsed-time gate and
// normalization so this exercises the fold arithmetic alone. Timing behaviour is
// covered by TestFoldOccupancyRampNormalizesIrregularTicks.
func TestFoldOccupancyRampIgnoresDecreases(t *testing.T) {
	s := newWarmPoolState()
	now := time.Now()
	// first observation only seeds the baseline
	s.foldOccupancyRamp(map[string]int{"m": 100}, now, 0, 0, 1.0)
	if got := s.models["m"].occupancyRampEWMA; got != 0 {
		t.Fatalf("after seed, ramp = %v, want 0", got)
	}
	// +50 rise, alpha=1 -> ramp == 50
	s.foldOccupancyRamp(map[string]int{"m": 150}, now, 0, 0, 1.0)
	if got := s.models["m"].occupancyRampEWMA; got != 50 {
		t.Fatalf("after +50, ramp = %v, want 50", got)
	}
	// big DROP must fold as 0, not negative
	s.foldOccupancyRamp(map[string]int{"m": 10}, now, 0, 0, 1.0)
	if got := s.models["m"].occupancyRampEWMA; got != 0 {
		t.Fatalf("after drop, ramp = %v, want 0 (floored, not negative)", got)
	}
	if got := s.models["m"].lastOccupancy; got != 10 {
		t.Fatalf("lastOccupancy = %d, want 10 (baseline still tracks the drop)", got)
	}
}

// OccupancyRamp is slots per CONTROL INTERVAL, but coalesced hot-path triggers
// (RequestWarmPoolTrigger from the queue/rejection paths) make planning passes
// irregular. Pre-fix the raw per-pass delta was folded, so one interval's growth
// split across N triggers measured ~1/N of the true ramp — under-warming during
// exactly the bursts that produce the extra triggers.
func TestFoldOccupancyRampNormalizesIrregularTicks(t *testing.T) {
	const interval = 30 * time.Second
	base := time.Now()

	// Six trigger-driven passes 5s apart, occupancy climbing 10 slots each: the
	// true growth is 60 slots over the 30s interval.
	burst := newWarmPoolState()
	burst.foldOccupancyRamp(map[string]int{"m": 0}, base, interval, interval/2, 1.0)
	for i := 1; i <= 6; i++ {
		at := base.Add(time.Duration(i) * 5 * time.Second)
		burst.foldOccupancyRamp(map[string]int{"m": i * 10}, at, interval, interval/2, 1.0)
	}
	if got := burst.models["m"].occupancyRampEWMA; got != 60 {
		t.Fatalf("bursty ticks: ramp = %v, want 60 (one interval of growth)", got)
	}

	// The same growth observed as a single on-interval pass must measure the same.
	steady := newWarmPoolState()
	steady.foldOccupancyRamp(map[string]int{"m": 0}, base, interval, interval/2, 1.0)
	steady.foldOccupancyRamp(map[string]int{"m": 60}, base.Add(interval), interval, interval/2, 1.0)
	if got := steady.models["m"].occupancyRampEWMA; got != 60 {
		t.Fatalf("steady tick: ramp = %v, want 60", got)
	}

	// A pass that arrives at half the interval is scaled UP, not counted raw:
	// 20 slots in 15s is a 40-slot/interval growth rate.
	half := newWarmPoolState()
	half.foldOccupancyRamp(map[string]int{"m": 0}, base, interval, interval/2, 1.0)
	half.foldOccupancyRamp(map[string]int{"m": 20}, base.Add(interval/2), interval, interval/2, 1.0)
	if got := half.models["m"].occupancyRampEWMA; got != 40 {
		t.Fatalf("half-interval tick: ramp = %v, want 40 (normalized)", got)
	}
}

// The pressure window expiring must NOT destroy the occupancy baseline.
//
// Pre-fix both lived on lastEventAt, which only pressure/load events advance. Once
// the last event aged out, every snapshot cleared haveOccupancy — and plan() calls
// snapshot twice per pass — so foldOccupancyRamp could only ever re-seed the
// baseline and never measure another rise until a new failure arrived. Proactive
// warming switched itself off ~2 minutes after the last shed request, which is the
// failure-triggered behaviour this whole change removes.
func TestOccupancyBaselineSurvivesPressureExpiry(t *testing.T) {
	const (
		window   = 2 * time.Minute
		interval = 30 * time.Second
	)
	s := newWarmPoolState()
	t0 := time.Now()

	// One pressure event, then it ages out completely.
	s.recordEvent("m", warmPoolEventCapacityReject, t0)
	stale := t0.Add(10 * time.Minute)

	// Reproduce a planning pass: fold, snapshot, fold, snapshot (as plan() does).
	for i := 0; i < 3; i++ {
		at := stale.Add(time.Duration(i) * interval)
		s.foldOccupancyRamp(map[string]int{"m": 100 + i*40}, at, interval, interval/2, 1.0)
		s.snapshot(at, window)
		s.snapshot(at, window)
	}

	b := s.models["m"]
	if !b.haveOccupancy {
		t.Fatal("haveOccupancy was cleared by pressure expiry: the baseline can never difference again")
	}
	if b.occupancyRampEWMA != 40 {
		t.Fatalf("ramp = %v, want 40 (measured across passes with no pressure at all)", b.occupancyRampEWMA)
	}
	// Pressure counters, on their own clock, must still have expired.
	snap := s.snapshot(stale, window)
	if snap["m"].capacityRejects != 0 {
		t.Fatalf("capacityRejects = %d, want 0 (pressure still expires on lastEventAt)", snap["m"].capacityRejects)
	}
	if snap["m"].occupancyRampEWMA != 40 {
		t.Fatalf("snapshot ramp = %v, want 40 (occupancy is not pressure)", snap["m"].occupancyRampEWMA)
	}
}

// The occupancy baseline has its OWN staleness clock: a model the controller stops
// reporting altogether does eventually lose its ramp, so a stale growth figure
// cannot keep warming providers forever.
func TestOccupancyBaselineExpiresOnItsOwnClock(t *testing.T) {
	const (
		window   = 2 * time.Minute
		interval = 30 * time.Second
	)
	s := newWarmPoolState()
	t0 := time.Now()
	s.foldOccupancyRamp(map[string]int{"m": 10}, t0, interval, interval/2, 1.0)
	s.foldOccupancyRamp(map[string]int{"m": 60}, t0.Add(interval), interval, interval/2, 1.0)
	if got := s.models["m"].occupancyRampEWMA; got != 50 {
		t.Fatalf("ramp = %v, want 50", got)
	}
	// No occupancy observed for well over the window.
	snap := s.snapshot(t0.Add(30*time.Minute), window)
	if snap["m"].occupancyRampEWMA != 0 || snap["m"].haveOccupancy {
		t.Fatalf("stale occupancy not expired: ramp=%v haveOccupancy=%v",
			snap["m"].occupancyRampEWMA, snap["m"].haveOccupancy)
	}
}

// A provider saturated by a CO-RESIDENT model is counted in Warm but can serve
// nothing for this model, and the requests consuming its capacity are absent from
// this model's occupancy. Pre-fix ceil(occupied/qc)+headroom could therefore sit
// below Warm and issue NO loads while every warm provider was unusable.
func TestHeadroomAccountsForCrossModelSaturation(t *testing.T) {
	p := derivedParams(64, 1)
	// 10 warm, all blocked by another model: zero of this model's requests are in
	// flight, so occupied = 0 and the uncorrected floor is just the ramp (2).
	in := warmTargetInputs{
		Model: "m", Warm: 10, WarmSaturated: 10, WarmForeignBlocked: 10,
		EligibleCold: 20, RunningRequests: 0, OccupancyRamp: 14, // ceil(14/7)=2
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	// 0 + 2 + 10 blocked = 12, above warm=10, so loads are actually issued.
	if got := warmTarget(in, p, time.Second); got != 12 {
		t.Fatalf("warmTarget = %d, want 12 (2 headroom + 10 foreign-blocked)", got)
	}

	// Self-saturation is NOT added: that load is already inside `occupied`.
	self := in
	self.WarmForeignBlocked = 0
	self.RunningRequests = 70 // == warm*qc, fully busy with its OWN traffic
	// ceil(70/7)=10 + 2 = 12, and nothing extra for the 10 saturated providers.
	if got := warmTarget(self, p, time.Second); got != 12 {
		t.Fatalf("warmTarget(self-saturated) = %d, want 12 (no double-count)", got)
	}

	// Partial: 4 of 10 blocked by a co-resident model, 6 busy with this model.
	partial := in
	partial.WarmForeignBlocked = 4
	partial.RunningRequests = 42 // 6 providers * qc 7
	// ceil(42/7)=6 + 2 + 4 = 12.
	if got := warmTarget(partial, p, time.Second); got != 12 {
		t.Fatalf("warmTarget(partial) = %d, want 12", got)
	}
}

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
	reg.warmPool.tick(t0)
	warmProviders[0].mu.Lock()
	warmProviders[0].BackendCapacity.Slots[0].NumRunning = 1
	warmProviders[0].mu.Unlock()
	reg.warmPool.tick(t0.Add(cfg.Interval))

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
	snaps := reg.warmPool.tick(t0.Add(2 * cfg.Interval))

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

// HEADROOM=false must be a TRUE opt-out, not just a suppressed floor.
//
// Both halves of proactive growth are new here: the headroom floor AND sizing to
// already-served load without a pressure signal. Pre-fix the kill switch only
// removed the first, so the unconditional Little's Law target still grew the pool
// with nothing failing — an operator reaching for the documented revert during an
// incident would not have got the previous behaviour.
func TestHeadroomDisabledGatesAllNoPressureGrowth(t *testing.T) {
	p := derivedParams(64, 1)
	p.HeadroomEnabledParams = false
	p.BurstBuffer = 1

	// Served load with NO pressure: pre-change this returned in.Warm.
	in := warmTargetInputs{
		Model: "m", Warm: 1, EligibleCold: 20, RunningRequests: 8,
		OccupancyRamp: 700, SoloDecodeTPS: 20, MaxProviderConc: 6,
		DemandPressure: false,
	}
	if got := warmTarget(in, p, time.Second); got != 1 {
		t.Fatalf("warmTarget = %d, want 1 (disabled: no growth without pressure)", got)
	}
	// Spill arrivals with no pressure flag must not grow it either.
	spill := in
	spill.RunningRequests = 0
	spill.SpillArrivalRate = 2.0
	if got := warmTarget(spill, p, 5*time.Second); got != 1 {
		t.Fatalf("warmTarget(spill) = %d, want 1 (disabled)", got)
	}
	// With pressure, the pre-change reactive path is intact: demand-sized target
	// (ceil(8/qc=1) = 8, plus BurstBuffer 1).
	withPressure := in
	withPressure.DemandPressure = true
	if got := warmTarget(withPressure, p, time.Second); got != 9 {
		t.Fatalf("warmTarget(pressure) = %d, want 9 (reactive Little's Law + burst buffer)", got)
	}
	// And with the floor ENABLED the same no-pressure input does grow, so the
	// switch is what makes the difference rather than the inputs.
	on := p
	on.HeadroomEnabledParams = true
	if got := warmTarget(in, on, time.Second); got <= 1 {
		t.Fatalf("warmTarget(enabled) = %d, want > 1 (the switch is the only difference)", got)
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
	reg.warmPool.tick(t0)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].Model = model
	warm.BackendCapacity.Slots[0].State = "running"
	warm.BackendCapacity.Slots[0].NumRunning = 20
	warm.mu.Unlock()
	snaps := reg.warmPool.tick(t0.Add(cfg.Interval))

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
