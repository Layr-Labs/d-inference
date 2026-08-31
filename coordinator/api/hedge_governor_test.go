package api

import (
	"sync"
	"testing"
)

// TestHedgeGovernorVerdictTable pins each launch rule, its precedence, and its
// boundary. Rules fire in order (queued → idle capacity → global budget →
// win rate), so each suppression names the FIRST failing condition.
func TestHedgeGovernorVerdictTable(t *testing.T) {
	// A baseline snapshot that passes every rule; each case perturbs it.
	allow := hedgeGovernorInputs{
		idleAlternativeExists: true,
		modelQueueDepth:       0,
		activeHedges:          0,
		fleetIdleSlots:        8,
		modelWinRate:          hedgeWinRateUnknown,
	}
	tests := []struct {
		name string
		in   hedgeGovernorInputs
		want hedgeVerdict
	}{
		{"all rules pass", allow, hedgeAllow},
		{
			"zero-value inputs fail closed",
			hedgeGovernorInputs{},
			hedgeSuppressNoIdleCapacity,
		},
		{
			"queued model never hedges",
			func() hedgeGovernorInputs { in := allow; in.modelQueueDepth = 1; return in }(),
			hedgeSuppressQueued,
		},
		{
			"queue outranks every other failure",
			hedgeGovernorInputs{modelQueueDepth: 3, modelWinRate: 0.01},
			hedgeSuppressQueued,
		},
		{
			"no idle alternative, fleet headroom below threshold",
			hedgeGovernorInputs{
				fleetIdleSlots: hedgeFleetIdleHeadroomSlots - 1,
				modelWinRate:   hedgeWinRateUnknown,
			},
			hedgeSuppressNoIdleCapacity,
		},
		{
			"no idle alternative, fleet headroom at threshold",
			hedgeGovernorInputs{
				fleetIdleSlots: hedgeFleetIdleHeadroomSlots,
				modelWinRate:   hedgeWinRateUnknown,
			},
			hedgeAllow,
		},
		{
			"idle alternative substitutes for zero fleet headroom",
			hedgeGovernorInputs{
				idleAlternativeExists: true,
				fleetIdleSlots:        0,
				modelWinRate:          hedgeWinRateUnknown,
			},
			hedgeAllow, // budget floor of 1 with idle capacity, activeHedges 0
		},
		{
			"budget boundary: last slot under budget allows",
			func() hedgeGovernorInputs {
				in := allow // budget = 8/4 = 2
				in.activeHedges = 1
				return in
			}(),
			hedgeAllow,
		},
		{
			"budget boundary: at budget suppresses",
			func() hedgeGovernorInputs {
				in := allow // budget = 8/4 = 2
				in.activeHedges = 2
				return in
			}(),
			hedgeSuppressGlobalBudget,
		},
		{
			"budget floor of one is consumable",
			hedgeGovernorInputs{
				idleAlternativeExists: true,
				fleetIdleSlots:        0,
				activeHedges:          1,
				modelWinRate:          hedgeWinRateUnknown,
			},
			hedgeSuppressGlobalBudget,
		},
		{
			"win rate below floor suppresses",
			func() hedgeGovernorInputs {
				in := allow
				in.modelWinRate = hedgeWinRateFloor - 0.01
				return in
			}(),
			hedgeSuppressWinRate,
		},
		{
			"win rate at floor allows",
			func() hedgeGovernorInputs {
				in := allow
				in.modelWinRate = hedgeWinRateFloor
				return in
			}(),
			hedgeAllow,
		},
		{
			"unknown win rate passes through",
			func() hedgeGovernorInputs {
				in := allow
				in.modelWinRate = hedgeWinRateUnknown
				return in
			}(),
			hedgeAllow,
		},
		{
			"zero win rate suppresses",
			func() hedgeGovernorInputs {
				in := allow
				in.modelWinRate = 0
				return in
			}(),
			hedgeSuppressWinRate,
		},
	}
	for _, tt := range tests {
		if got := hedgeGovernorVerdict(tt.in); got != tt.want {
			t.Errorf("%s: verdict = %v, want %v", tt.name, got, tt.want)
		}
	}
}

// TestHedgeGlobalBudget pins the budget arithmetic and its two boundary
// behaviors: zero with no idle capacity anywhere, floor of one whenever any
// idle capacity exists, and the divisor above the floor.
func TestHedgeGlobalBudget(t *testing.T) {
	tests := []struct {
		fleetIdleSlots int
		idleAlt        bool
		want           int
	}{
		{0, false, 0}, // saturated fleet runs no insurance
		{0, true, 1},  // model-scoped idle alternative keeps the floor
		{1, false, 1}, // 1/4 rounds to 0 → floor
		{3, false, 1},
		{4, false, 1},
		{8, false, 2},
		{100, false, 25},
	}
	for _, tt := range tests {
		if got := hedgeGlobalBudget(tt.fleetIdleSlots, tt.idleAlt); got != tt.want {
			t.Errorf("hedgeGlobalBudget(%d, %v) = %d, want %d",
				tt.fleetIdleSlots, tt.idleAlt, got, tt.want)
		}
	}
}

// TestHedgeVerdictStrings pins the bounded verdict vocabulary used as the
// routing.hedge_governor_suppressed metric tag and log field.
func TestHedgeVerdictStrings(t *testing.T) {
	tests := []struct {
		v    hedgeVerdict
		want string
	}{
		{hedgeAllow, "allow"},
		{hedgeSuppressQueued, "suppress_queued"},
		{hedgeSuppressNoIdleCapacity, "suppress_no_idle_capacity"},
		{hedgeSuppressGlobalBudget, "suppress_global_budget"},
		{hedgeSuppressWinRate, "suppress_win_rate"},
		{hedgeVerdict(99), "unknown"},
	}
	for _, tt := range tests {
		if got := tt.v.String(); got != tt.want {
			t.Errorf("hedgeVerdict(%d).String() = %q, want %q", tt.v, got, tt.want)
		}
	}
}

// TestHedgeGovernorCounterConcurrency drives balanced launch/resolve pairs
// from many goroutines: the counter must end at zero, and the clamped
// decrement means over-resolving from a stray goroutine can never push it
// negative (which would inflate the budget forever).
func TestHedgeGovernorCounterConcurrency(t *testing.T) {
	t.Parallel()
	g := newHedgeGovernor()
	const goroutines = 16
	const pairsPerGoroutine = 500

	var wg sync.WaitGroup
	for range goroutines {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range pairsPerGoroutine {
				g.noteHedgeLaunched()
				g.noteHedgeResolved()
			}
		}()
	}
	wg.Wait()
	if got := g.activeHedgeCount(); got != 0 {
		t.Fatalf("active hedges after balanced pairs = %d, want 0", got)
	}

	// Over-resolve: the clamp holds the floor at zero.
	g.noteHedgeResolved()
	g.noteHedgeResolved()
	if got := g.activeHedgeCount(); got != 0 {
		t.Fatalf("active hedges after over-resolve = %d, want 0 (clamped)", got)
	}
}

// TestHedgeGovernorWinRateEWMA verifies the per-model feedback loop: unknown
// until the first outcome, first sample seeds directly (RecordLatency
// pattern), later samples blend at hedgeWinRateAlpha, and models are tracked
// independently.
func TestHedgeGovernorWinRateEWMA(t *testing.T) {
	g := newHedgeGovernor()

	if got := g.modelWinRate("model-a"); got != hedgeWinRateUnknown {
		t.Fatalf("win rate before any outcome = %v, want %v", got, hedgeWinRateUnknown)
	}

	// First sample seeds directly.
	g.recordHedgeOutcome("model-a", true)
	if got := g.modelWinRate("model-a"); got != 1.0 {
		t.Fatalf("win rate after first win = %v, want 1.0", got)
	}

	// Second sample blends: 1.0*0.8 + 0.0*0.2 = 0.8.
	g.recordHedgeOutcome("model-a", false)
	if got := g.modelWinRate("model-a"); got != 0.8 {
		t.Fatalf("win rate after loss = %v, want 0.8", got)
	}

	// Models are independent; a losing seed lands under the floor.
	g.recordHedgeOutcome("model-b", false)
	if got := g.modelWinRate("model-b"); got != 0.0 {
		t.Fatalf("model-b win rate = %v, want 0.0", got)
	}
	if got := g.modelWinRate("model-a"); got != 0.8 {
		t.Fatalf("model-a win rate disturbed by model-b: %v, want 0.8", got)
	}

	// The seeded-loss model suppresses; the healthy model still allows.
	in := hedgeGovernorInputs{
		idleAlternativeExists: true,
		fleetIdleSlots:        8,
		modelWinRate:          g.modelWinRate("model-b"),
	}
	if got := hedgeGovernorVerdict(in); got != hedgeSuppressWinRate {
		t.Fatalf("all-loss model verdict = %v, want suppress_win_rate", got)
	}
	in.modelWinRate = g.modelWinRate("model-a")
	if got := hedgeGovernorVerdict(in); got != hedgeAllow {
		t.Fatalf("healthy model verdict = %v, want allow", got)
	}
}

// TestHedgeGovernorWinRateConcurrency hammers outcome recording and reads for
// disjoint and shared models from parallel goroutines: purely a race-safety
// probe (run under -race), with a bounds check that the EWMA of {0,1} samples
// can never leave [0,1].
func TestHedgeGovernorWinRateConcurrency(t *testing.T) {
	t.Parallel()
	g := newHedgeGovernor()
	models := []string{"shared", "shared", "solo-a", "solo-b"}

	var wg sync.WaitGroup
	for i, model := range models {
		wg.Add(1)
		go func(model string, won bool) {
			defer wg.Done()
			for range 500 {
				g.recordHedgeOutcome(model, won)
				g.modelWinRate(model)
			}
		}(model, i%2 == 0)
	}
	wg.Wait()

	for _, model := range []string{"shared", "solo-a", "solo-b"} {
		rate := g.modelWinRate(model)
		if rate < 0 || rate > 1 {
			t.Fatalf("win rate for %q = %v, want within [0,1]", model, rate)
		}
	}
	if got := g.modelWinRate("never-hedged"); got != hedgeWinRateUnknown {
		t.Fatalf("untouched model rate = %v, want unknown", got)
	}
}
