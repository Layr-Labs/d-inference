package warmpool

import (
	"github.com/eigeninference/d-inference/coordinator/registry/throughput"
	"testing"
	"time"
)

// derivedParams: floor comes from the measured ramp, no operator override.
func derivedParams(maxProviders int, windows float64) Params {
	return Params{
		DecodeFloorTPS:             15,
		LoadFactorK:                throughput.LoadFactor,
		BurstBuffer:                0,
		HeadroomEnabledParams:      true,
		HeadroomMaxProviders:       maxProviders,
		HeadroomLoadWindows:        windows,
		FallbackQualityConcurrency: 4,
		AssumedPromptTokens:        512,
		AssumedCompletionTokens:    256,
		MinServiceTime:             MinServiceTime,
		MaxServiceTime:             MaxServiceTime,
	}
}

// overrideParams: an explicit per-model pin.
func overrideParams(m map[string]int) Params {
	p := derivedParams(64, 1)
	p.HeadroomProviders = m
	return p
}

// The pool grows on MEASURED demand growth with NO pressure signal at all.
// Pre-fix this returned in.Warm unchanged (nothing warmed until a request failed).
func TestHeadroomWarmsWithoutAnyPressureSignal(t *testing.T) {
	p := derivedParams(64, 1)
	in := Inputs{
		Model: "m", Warm: 5, WarmSaturated: 0, EligibleCold: 50,
		RunningRequests: 0, OccupancyRamp: 40, // 40 slots/interval of growth
		SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	// qc=7 -> ceil(40/7)=6 providers of headroom; occupied 0 -> target 6.
	if got := Target(in, p, time.Second); got != 6 {
		t.Fatalf("Target = %d, want 6 (derived floor, zero pressure)", got)
	}
}

// A model with no measured ramp gets NO proactive warming — the conservative
// direction. This is what keeps a brand-new build from being warmed on a guess.
func TestHeadroomNoRampNoProactiveWarming(t *testing.T) {
	p := derivedParams(64, 1)
	in := Inputs{
		Model: "m", Warm: 5, EligibleCold: 50, RunningRequests: 0,
		OccupancyRamp: 0, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	if got := Target(in, p, time.Second); got != 5 {
		t.Fatalf("Target = %d, want 5 (no ramp measured -> stay put)", got)
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
		in := Inputs{
			Model: "m", Warm: 1, EligibleCold: 500, RunningRequests: 0,
			OccupancyRamp: float64(tc.ramp), SoloDecodeTPS: 60, MaxProviderConc: 8,
			DemandPressure: false,
		}
		if got := Target(in, p, time.Second); got != tc.want {
			t.Errorf("ramp=%d: Target = %d, want %d", tc.ramp, got, tc.want)
		}
	}
}

// An explicit per-model override wins over the derived value, and applies only to
// the named model.
func TestHeadroomPerModelOverride(t *testing.T) {
	p := overrideParams(map[string]int{"pinned": 20})
	base := Inputs{
		Warm: 1, EligibleCold: 500, RunningRequests: 0,
		OccupancyRamp: 7, // would derive ceil(7/7)=1
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	pinned := base
	pinned.Model = "pinned"
	if got := Target(pinned, p, time.Second); got != 20 {
		t.Fatalf("pinned model: Target = %d, want 20 (override)", got)
	}
	other := base
	other.Model = "other"
	if got := Target(other, p, time.Second); got != 1 {
		t.Fatalf("unpinned model: Target = %d, want 1 (derived)", got)
	}
}

// The derived floor is capped so a pathological ramp cannot demand the fleet.
// An operator override is NOT capped — naming a number means it.
func TestHeadroomMaxProvidersCapsDerivedNotOverride(t *testing.T) {
	in := Inputs{
		Model: "m", Warm: 1, EligibleCold: 5000, RunningRequests: 0,
		OccupancyRamp: 7000, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	// derived would be ceil(7000/7)=1000, capped to 10
	if got := Target(in, derivedParams(10, 1), time.Second); got != 10 {
		t.Fatalf("derived: Target = %d, want 10 (capped)", got)
	}
	p := overrideParams(map[string]int{"m": 900})
	p.HeadroomMaxProviders = 10
	if got := Target(in, p, time.Second); got != 900 {
		t.Fatalf("override: Target = %d, want 900 (uncapped)", got)
	}
}

// LoadWindows scales the floor by how long a cold load takes.
func TestHeadroomLoadWindowsScalesFloor(t *testing.T) {
	in := Inputs{
		Model: "m", Warm: 1, EligibleCold: 500, RunningRequests: 0,
		OccupancyRamp: 14, SoloDecodeTPS: 60, MaxProviderConc: 8,
		DemandPressure: false,
	}
	// qc=7: 1 window -> ceil(14/7)=2 ; 2 windows -> ceil(28/7)=4
	if got := Target(in, derivedParams(64, 1), time.Second); got != 2 {
		t.Fatalf("1 window: Target = %d, want 2", got)
	}
	if got := Target(in, derivedParams(64, 2), time.Second); got != 4 {
		t.Fatalf("2 windows: Target = %d, want 4", got)
	}
}

// Headroom is expressed in CAPACITY, so a saturated provider is accounted for by
// the requests occupying it, NOT by adding WarmSaturated to the floor — that
// double-counts, since its capacity is already inside warm*qc.
func TestHeadroomDoesNotDoubleCountSaturated(t *testing.T) {
	p := derivedParams(64, 1)
	base := Inputs{
		Model: "m", Warm: 20, EligibleCold: 50, RunningRequests: 40,
		OccupancyRamp: 70, // ceil(70/7)=10 providers of headroom
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	// ceil(40/7)=6 + 10 = 16, below warm=20 -> stays 20, whatever saturated says.
	for _, sat := range []int{0, 5, 15, 20} {
		in := base
		in.WarmSaturated = sat
		if got := Target(in, p, time.Second); got != 20 {
			t.Errorf("saturated=%d: Target = %d, want 20 (occupancy is what counts)", sat, got)
		}
	}
	// Fully-busy pool: occupied == warm*qc = 140. ceil(140/7)=20 + 10 = 30,
	// NOT 30+20 (the double-counted value the first implementation produced).
	busy := base
	busy.RunningRequests = 140
	busy.WarmSaturated = 20
	if got := Target(busy, p, time.Second); got != 30 {
		t.Fatalf("Target(fully busy) = %d, want 30 (no saturated double-count)", got)
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
		in := Inputs{
			Model: "m", Warm: 1, WarmSaturated: 0, EligibleCold: 5000,
			RunningRequests: tc.running, OccupancyRamp: 70, // -> 10 providers
			SoloDecodeTPS: 60, MaxProviderConc: 8,
			DemandPressure: false,
		}
		if got := Target(in, p, time.Second); got != tc.want {
			t.Errorf("running=%d: Target = %d, want %d", tc.running, got, tc.want)
		}
	}
}

// A pool already far larger than its load does NOT grow on the headroom floor —
// the floor is about spare capacity, not pool size.
func TestHeadroomIdleOversizedPoolOnlyNudges(t *testing.T) {
	p := derivedParams(64, 1)
	p.BurstBuffer = 1
	in := Inputs{
		Model: "m", Warm: 300, WarmSaturated: 300, EligibleCold: 200,
		RunningRequests: 600, OccupancyRamp: 175, // ceil(175/7)=25
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: true,
	}
	// ceil(600/7)=86 + 25 = 111, well below warm=300 -> reactive nudge only.
	if got := Target(in, p, time.Second); got != in.Warm+1 {
		t.Fatalf("Target = %d, want %d (reactive nudge only)", got, in.Warm+1)
	}
}

// A shortfall exceeding the current pool closes in ONE tick, not +1 per interval.
func TestHeadroomClosesShortfallExceedingPoolInOneTick(t *testing.T) {
	p := derivedParams(64, 1)
	p.BurstBuffer = 1
	in := Inputs{
		Model: "m", Warm: 100, WarmSaturated: 100, EligibleCold: 400,
		RunningRequests: 2100, OccupancyRamp: 175, // ceil(175/7)=25
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: true,
	}
	// ceil(2100/7)=300 + 25 = 325, far above warm+1=101.
	got := Target(in, p, time.Second)
	if got != 325 {
		t.Fatalf("Target = %d, want 325", got)
	}
	if got <= in.Warm+1 {
		t.Fatalf("target %d did not beat the +1/tick reactive floor", got)
	}
}

// The floor never demands hardware that does not exist.
func TestHeadroomCappedByReachable(t *testing.T) {
	p := derivedParams(64, 1)
	in := Inputs{
		Model: "m", Warm: 5, WarmSaturated: 5, EligibleCold: 3,
		RunningRequests: 0, OccupancyRamp: 700, // would want 100 providers
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	if got := Target(in, p, time.Second); got != 8 {
		t.Fatalf("Target = %d, want 8 (warm+eligibleCold ceiling)", got)
	}
}

// Disabling restores the exact pre-fix reactive behaviour.
func TestHeadroomDisabledIsOptOut(t *testing.T) {
	p := derivedParams(64, 1)
	p.HeadroomEnabledParams = false
	p.BurstBuffer = 1
	in := Inputs{
		Model: "m", Warm: 5, WarmSaturated: 5, EligibleCold: 50,
		RunningRequests: 0, OccupancyRamp: 700,
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	if got := Target(in, p, time.Second); got != 5 {
		t.Fatalf("Target = %d, want 5 (headroom disabled, no pressure)", got)
	}
	withPressure := in
	withPressure.DemandPressure = true
	if got := Target(withPressure, p, time.Second); got != 6 {
		t.Fatalf("Target = %d, want 6 (reactive nudge preserved)", got)
	}
}

// The pool must never SHRINK as a result of this change.
func TestHeadroomNeverShrinksPool(t *testing.T) {
	p := derivedParams(64, 1)
	in := Inputs{
		Model: "m", Warm: 500, WarmSaturated: 0, EligibleCold: 0,
		RunningRequests: 0, OccupancyRamp: 7,
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	if got := Target(in, p, time.Second); got != 500 {
		t.Fatalf("Target = %d, want 500 (never shrink below current warm)", got)
	}
}

// FoldOccupancyRamp: only INCREASES are folded, so a draining spike does not
// shrink headroom right when the next spike is most likely.
//
// interval/minInterval are 0 here, which disables the elapsed-time gate and
// normalization so this exercises the fold arithmetic alone. Timing behaviour is
// covered by TestFoldOccupancyRampNormalizesIrregularTicks.
func TestFoldOccupancyRampIgnoresDecreases(t *testing.T) {
	s := NewState()
	now := time.Now()
	// first observation only seeds the baseline
	s.FoldOccupancyRamp(map[string]int{"m": 100}, now, 0, 0, 1.0)
	if got := s.models["m"].OccupancyRampEWMA; got != 0 {
		t.Fatalf("after seed, ramp = %v, want 0", got)
	}
	// +50 rise, alpha=1 -> ramp == 50
	s.FoldOccupancyRamp(map[string]int{"m": 150}, now, 0, 0, 1.0)
	if got := s.models["m"].OccupancyRampEWMA; got != 50 {
		t.Fatalf("after +50, ramp = %v, want 50", got)
	}
	// big DROP must fold as 0, not negative
	s.FoldOccupancyRamp(map[string]int{"m": 10}, now, 0, 0, 1.0)
	if got := s.models["m"].OccupancyRampEWMA; got != 0 {
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
	burst := NewState()
	burst.FoldOccupancyRamp(map[string]int{"m": 0}, base, interval, interval/2, 1.0)
	for i := 1; i <= 6; i++ {
		at := base.Add(time.Duration(i) * 5 * time.Second)
		burst.FoldOccupancyRamp(map[string]int{"m": i * 10}, at, interval, interval/2, 1.0)
	}
	if got := burst.models["m"].OccupancyRampEWMA; got != 60 {
		t.Fatalf("bursty ticks: ramp = %v, want 60 (one interval of growth)", got)
	}

	// The same growth observed as a single on-interval pass must measure the same.
	steady := NewState()
	steady.FoldOccupancyRamp(map[string]int{"m": 0}, base, interval, interval/2, 1.0)
	steady.FoldOccupancyRamp(map[string]int{"m": 60}, base.Add(interval), interval, interval/2, 1.0)
	if got := steady.models["m"].OccupancyRampEWMA; got != 60 {
		t.Fatalf("steady tick: ramp = %v, want 60", got)
	}

	// A pass that arrives at half the interval is scaled UP, not counted raw:
	// 20 slots in 15s is a 40-slot/interval growth rate.
	half := NewState()
	half.FoldOccupancyRamp(map[string]int{"m": 0}, base, interval, interval/2, 1.0)
	half.FoldOccupancyRamp(map[string]int{"m": 20}, base.Add(interval/2), interval, interval/2, 1.0)
	if got := half.models["m"].OccupancyRampEWMA; got != 40 {
		t.Fatalf("half-interval tick: ramp = %v, want 40 (normalized)", got)
	}
}

// The pressure window expiring must NOT destroy the occupancy baseline.
//
// Pre-fix both lived on lastEventAt, which only pressure/load events advance. Once
// the last event aged out, every Snapshot cleared haveOccupancy — and plan() calls
// Snapshot twice per pass — so FoldOccupancyRamp could only ever re-seed the
// baseline and never measure another rise until a new failure arrived. Proactive
// warming switched itself off ~2 minutes after the last shed request, which is the
// failure-triggered behaviour this whole change removes.
func TestOccupancyBaselineSurvivesPressureExpiry(t *testing.T) {
	const (
		window   = 2 * time.Minute
		interval = 30 * time.Second
	)
	s := NewState()
	t0 := time.Now()

	// One pressure event, then it ages out completely.
	s.RecordEvent("m", CapacityReject, t0)
	stale := t0.Add(10 * time.Minute)

	// Reproduce a planning pass: fold, Snapshot, fold, Snapshot (as plan() does).
	for i := 0; i < 3; i++ {
		at := stale.Add(time.Duration(i) * interval)
		s.FoldOccupancyRamp(map[string]int{"m": 100 + i*40}, at, interval, interval/2, 1.0)
		s.Snapshot(at, window)
		s.Snapshot(at, window)
	}

	b := s.models["m"]
	if !b.haveOccupancy {
		t.Fatal("haveOccupancy was cleared by pressure expiry: the baseline can never difference again")
	}
	if b.OccupancyRampEWMA != 40 {
		t.Fatalf("ramp = %v, want 40 (measured across passes with no pressure at all)", b.OccupancyRampEWMA)
	}
	// Pressure counters, on their own clock, must still have expired.
	snap := s.Snapshot(stale, window)
	if snap["m"].CapacityRejects != 0 {
		t.Fatalf("CapacityRejects = %d, want 0 (pressure still expires on lastEventAt)", snap["m"].CapacityRejects)
	}
	if snap["m"].OccupancyRampEWMA != 40 {
		t.Fatalf("Snapshot ramp = %v, want 40 (occupancy is not pressure)", snap["m"].OccupancyRampEWMA)
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
	s := NewState()
	t0 := time.Now()
	s.FoldOccupancyRamp(map[string]int{"m": 10}, t0, interval, interval/2, 1.0)
	s.FoldOccupancyRamp(map[string]int{"m": 60}, t0.Add(interval), interval, interval/2, 1.0)
	if got := s.models["m"].OccupancyRampEWMA; got != 50 {
		t.Fatalf("ramp = %v, want 50", got)
	}
	// No occupancy observed for well over the window.
	snap := s.Snapshot(t0.Add(30*time.Minute), window)
	if snap["m"].OccupancyRampEWMA != 0 || snap["m"].haveOccupancy {
		t.Fatalf("stale occupancy not expired: ramp=%v haveOccupancy=%v",
			snap["m"].OccupancyRampEWMA, snap["m"].haveOccupancy)
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
	in := Inputs{
		Model: "m", Warm: 10, WarmSaturated: 10, WarmForeignBlocked: 10,
		EligibleCold: 20, RunningRequests: 0, OccupancyRamp: 14, // ceil(14/7)=2
		SoloDecodeTPS: 60, MaxProviderConc: 8, DemandPressure: false,
	}
	// 0 + 2 + 10 blocked = 12, above warm=10, so loads are actually issued.
	if got := Target(in, p, time.Second); got != 12 {
		t.Fatalf("Target = %d, want 12 (2 headroom + 10 foreign-blocked)", got)
	}

	// Self-saturation is NOT added: that load is already inside `occupied`.
	self := in
	self.WarmForeignBlocked = 0
	self.RunningRequests = 70 // == warm*qc, fully busy with its OWN traffic
	// ceil(70/7)=10 + 2 = 12, and nothing extra for the 10 saturated providers.
	if got := Target(self, p, time.Second); got != 12 {
		t.Fatalf("Target(self-saturated) = %d, want 12 (no double-count)", got)
	}

	// Partial: 4 of 10 blocked by a co-resident model, 6 busy with this model.
	partial := in
	partial.WarmForeignBlocked = 4
	partial.RunningRequests = 42 // 6 providers * qc 7
	// ceil(42/7)=6 + 2 + 4 = 12.
	if got := Target(partial, p, time.Second); got != 12 {
		t.Fatalf("Target(partial) = %d, want 12", got)
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
	in := Inputs{
		Model: "m", Warm: 1, EligibleCold: 20, RunningRequests: 8,
		OccupancyRamp: 700, SoloDecodeTPS: 20, MaxProviderConc: 6,
		DemandPressure: false,
	}
	if got := Target(in, p, time.Second); got != 1 {
		t.Fatalf("Target = %d, want 1 (disabled: no growth without pressure)", got)
	}
	// Spill arrivals with no pressure flag must not grow it either.
	spill := in
	spill.RunningRequests = 0
	spill.SpillArrivalRate = 2.0
	if got := Target(spill, p, 5*time.Second); got != 1 {
		t.Fatalf("Target(spill) = %d, want 1 (disabled)", got)
	}
	// With pressure, the pre-change reactive path is intact: demand-sized target
	// (ceil(8/qc=1) = 8, plus BurstBuffer 1).
	withPressure := in
	withPressure.DemandPressure = true
	if got := Target(withPressure, p, time.Second); got != 9 {
		t.Fatalf("Target(pressure) = %d, want 9 (reactive Little's Law + burst buffer)", got)
	}
	// And with the floor ENABLED the same no-pressure input does grow, so the
	// switch is what makes the difference rather than the inputs.
	on := p
	on.HeadroomEnabledParams = true
	if got := Target(in, on, time.Second); got <= 1 {
		t.Fatalf("Target(enabled) = %d, want > 1 (the switch is the only difference)", got)
	}
}
