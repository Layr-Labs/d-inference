package warmpool

import (
	"github.com/eigeninference/d-inference/coordinator/registry/throughput"
	"testing"
	"time"
)

func TestWarmTargetLittlesLaw(t *testing.T) {
	params := Params{
		DecodeFloorTPS: 15,
		LoadFactorK:    throughput.LoadFactor,
		BurstBuffer:    0,
		// Proactive growth on, as in prod. No input here carries an OccupancyRamp,
		// so the headroom floor itself contributes 0 and these cases isolate the
		// Little's Law math. The disabled-switch behaviour is asserted in
		// TestHeadroomDisabledGatesAllNoPressureGrowth.
		HeadroomEnabledParams:      true,
		HeadroomMaxProviders:       64,
		HeadroomLoadWindows:        1,
		FallbackQualityConcurrency: 4,
		MinServiceTime:             MinServiceTime,
		MaxServiceTime:             MaxServiceTime,
	}
	// Served L=8 (in-flight), qc=1 (solo 20 vs floor 15) -> target ceil(8/1)=8.
	served := Inputs{
		Warm: 1, EligibleCold: 20, RunningRequests: 8,
		SoloDecodeTPS: 20, MaxProviderConc: 6, DemandPressure: true,
	}
	if got := Target(served, params, time.Second); got != 8 {
		t.Fatalf("Target(served) = %d, want 8", got)
	}
	// No demand pressure: the pool is still sized to the load it is ALREADY
	// carrying. This used to assert target==1 (leave the pool alone) — i.e. 8
	// requests in flight against 20 idle cold boxes still warmed nothing until
	// a request failed. Growth is no longer gated on a failure; the Little's
	// Law term alone covers served load.
	noPressure := served
	noPressure.DemandPressure = false
	if got := Target(noPressure, params, time.Second); got != 8 {
		t.Fatalf("Target(no pressure) = %d, want 8 (demand-sized without a failure)", got)
	}
	// Spill-driven: 2 req/s * E[S] 5s = 10 concurrent, qc=1 -> target 10.
	spill := Inputs{
		Warm: 0, EligibleCold: 20, SpillArrivalRate: 2.0,
		SoloDecodeTPS: 20, MaxProviderConc: 6, DemandPressure: true,
	}
	if got := Target(spill, params, 5*time.Second); got != 10 {
		t.Fatalf("Target(spill) = %d, want 10", got)
	}
	// Never exceed what the fleet can warm (warm + eligibleCold).
	capped := spill
	capped.EligibleCold = 3
	if got := Target(capped, params, 5*time.Second); got != 3 {
		t.Fatalf("Target(capped) = %d, want 3", got)
	}
	// A lone pressure event still nudges the pool forward by one (reactive floor).
	reactive := Inputs{
		Warm: 2, EligibleCold: 5, SoloDecodeTPS: 100, MaxProviderConc: 8, DemandPressure: true,
	}
	if got := Target(reactive, params, time.Second); got != 3 {
		t.Fatalf("Target(reactive floor) = %d, want 3", got)
	}
}

func TestRampLoadsThisTickDemandScaled(t *testing.T) {
	// Small gap is capped by the gap itself.
	if got := LoadsThisTick(1, 2, 16, 0.5); got != 1 {
		t.Fatalf("ramp(gap1) = %d, want 1", got)
	}
	// Gap at/below base burst -> base, capped by gap.
	if got := LoadsThisTick(5, 4, 16, 0.5); got != 4 {
		t.Fatalf("ramp(gap5,base4) = %d, want 4", got)
	}
	// Large gap -> fraction scales the burst above the base.
	if got := LoadsThisTick(20, 4, 16, 0.5); got != 10 {
		t.Fatalf("ramp(gap20,frac.5) = %d, want 10", got)
	}
	// Hard ceiling bounds the burst.
	if got := LoadsThisTick(100, 4, 16, 0.5); got != 16 {
		t.Fatalf("ramp(gap100) = %d, want 16 (ceiling)", got)
	}
	// Fraction 0 falls back to the flat base burst.
	if got := LoadsThisTick(20, 3, 16, 0); got != 3 {
		t.Fatalf("ramp(frac0) = %d, want 3 (base)", got)
	}
	// No gap -> no loads.
	if got := LoadsThisTick(0, 4, 16, 1.0); got != 0 {
		t.Fatalf("ramp(gap0) = %d, want 0", got)
	}
}

func TestEstimateServiceTimeClamped(t *testing.T) {
	p := Params{
		AssumedPromptTokens:     600,
		AssumedCompletionTokens: 256,
		MinServiceTime:          MinServiceTime,
		MaxServiceTime:          MaxServiceTime,
	}
	// prefill 600/600 = 1s + decode 256/50 = 5.12s ~= 6.12s.
	svc := ServiceTime(600, 50, p)
	if svc < 6*time.Second || svc > 7*time.Second {
		t.Fatalf("svc = %v, want ~6.12s", svc)
	}
	// Near-zero rates blow up E[S] -> clamp to the max.
	if got := ServiceTime(0.001, 0.001, p); got != MaxServiceTime {
		t.Fatalf("svc(tiny rates) = %v, want max %v", got, MaxServiceTime)
	}
	// Zero assumed tokens -> clamp to the min.
	p2 := p
	p2.AssumedPromptTokens = 0
	p2.AssumedCompletionTokens = 0
	if got := ServiceTime(50, 50, p2); got != MinServiceTime {
		t.Fatalf("svc(zero tokens) = %v, want min %v", got, MinServiceTime)
	}
}

func TestMedianFloat(t *testing.T) {
	if got := Median(nil); got != 0 {
		t.Fatalf("median(nil) = %v, want 0", got)
	}
	if got := Median([]float64{20}); got != 20 {
		t.Fatalf("median([20]) = %v, want 20", got)
	}
	if got := Median([]float64{30, 10, 20}); got != 20 {
		t.Fatalf("median(odd) = %v, want 20", got)
	}
	if got := Median([]float64{10, 20, 30, 40}); got != 25 {
		t.Fatalf("median(even) = %v, want 25", got)
	}
}

func TestWarmPoolFoldArrivalRates(t *testing.T) {
	s := NewState()
	model := "arrival"
	t0 := time.Now()
	for i := 0; i < 10; i++ {
		s.RecordEvent(model, CapacityReject, t0)
	}
	// First fold only establishes the baseline timestamp; no rate yet.
	s.FoldArrivalRates(t0, time.Second, 1.0)
	if got := s.Snapshot(t0, time.Minute)[model].ArrivalRateEWMA; got != 0 {
		t.Fatalf("first fold rate = %v, want 0", got)
	}
	// 10 spill arrivals accumulated; folding 10s later with alpha=1 yields the
	// instantaneous rate 10/10 = 1.0 req/s.
	t1 := t0.Add(10 * time.Second)
	s.FoldArrivalRates(t1, time.Second, 1.0)
	if got := s.Snapshot(t1, time.Minute)[model].ArrivalRateEWMA; got != 1.0 {
		t.Fatalf("folded rate = %v, want 1.0", got)
	}
	// Non-spill signals (speculative) do not inflate the arrival rate.
	s2 := NewState()
	s2.RecordEvent(model, SpeculativeStarted, t0)
	s2.FoldArrivalRates(t0, time.Second, 1.0)
	s2.FoldArrivalRates(t0.Add(10*time.Second), time.Second, 1.0)
	if got := s2.Snapshot(t0.Add(10*time.Second), time.Minute)[model].ArrivalRateEWMA; got != 0 {
		t.Fatalf("speculative arrival rate = %v, want 0", got)
	}
}
