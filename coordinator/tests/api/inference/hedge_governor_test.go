package inference_test

import (
	"sync"
	"testing"

	inferhedge "github.com/eigeninference/d-inference/coordinator/internal/inference/hedge"
)

// TestHedgeGovernorCounterConcurrency drives balanced launch/resolve pairs
// from many goroutines: the counter must end at zero, and the clamped
// decrement means over-resolving from a stray goroutine can never push it
// negative (which would inflate the budget forever).
func TestHedgeGovernorCounterConcurrency(t *testing.T) {
	t.Parallel()
	g := inferhedge.NewGovernor()
	const goroutines = 16
	const pairsPerGoroutine = 500

	var wg sync.WaitGroup
	for range goroutines {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range pairsPerGoroutine {
				_, acquired := g.TryAcquire("counter-concurrency", inferhedge.Inputs{IdleAlternativeExists: true, FleetIdleSlots: goroutines * inferhedge.GlobalBudgetDivisor})
				if !acquired {
					t.Error("spare budget unexpectedly rejected hedge")
					return
				}
				g.Resolve()
			}
		}()
	}
	wg.Wait()
	if got := g.ActiveCount(); got != 0 {
		t.Fatalf("active hedges after balanced pairs = %d, want 0", got)
	}

	// Over-resolve: the clamp holds the floor at zero.
	g.Resolve()
	g.Resolve()
	if got := g.ActiveCount(); got != 0 {
		t.Fatalf("active hedges after over-resolve = %d, want 0 (clamped)", got)
	}
}

// TestHedgeGovernorWinRateEWMA verifies the per-model feedback loop: unknown
// until the first outcome, first sample seeds directly (RecordLatency
// pattern), later samples blend at hedgeWinRateAlpha, and models are tracked
// independently.
func TestHedgeGovernorWinRateEWMA(t *testing.T) {
	g := inferhedge.NewGovernor()

	if got := g.ModelWinRate("model-a"); got != inferhedge.WinRateUnknown {
		t.Fatalf("win rate before any outcome = %v, want %v", got, inferhedge.WinRateUnknown)
	}

	// First sample seeds directly.
	g.RecordOutcome("model-a", true)
	if got := g.ModelWinRate("model-a"); got != 1.0 {
		t.Fatalf("win rate after first win = %v, want 1.0", got)
	}

	// Second sample blends: 1.0*0.8 + 0.0*0.2 = 0.8.
	g.RecordOutcome("model-a", false)
	if got := g.ModelWinRate("model-a"); got != 0.8 {
		t.Fatalf("win rate after loss = %v, want 0.8", got)
	}

	// Models are independent; a losing seed lands under the floor.
	g.RecordOutcome("model-b", false)
	if got := g.ModelWinRate("model-b"); got != 0.0 {
		t.Fatalf("model-b win rate = %v, want 0.0", got)
	}
	if got := g.ModelWinRate("model-a"); got != 0.8 {
		t.Fatalf("model-a win rate disturbed by model-b: %v, want 0.8", got)
	}

	// The seeded-loss model suppresses once its EWMA rests on enough
	// samples (the pure function is fed the count; the governor tracks it);
	// the healthy model still allows.
	in := inferhedge.Inputs{
		IdleAlternativeExists: true,
		FleetIdleSlots:        8,
		ModelWinRate:          g.ModelWinRate("model-b"),
		ModelWinRateSamples:   inferhedge.WinRateMinSamples,
	}
	if got := inferhedge.Evaluate(in); got != inferhedge.SuppressWinRate {
		t.Fatalf("all-loss model verdict = %v, want suppress_win_rate", got)
	}
	in.ModelWinRate = g.ModelWinRate("model-a")
	if got := inferhedge.Evaluate(in); got != inferhedge.Allow {
		t.Fatalf("healthy model verdict = %v, want allow", got)
	}
}

// TestHedgeGovernorWinRateConcurrency hammers outcome recording and reads for
// disjoint and shared models from parallel goroutines: purely a race-safety
// probe (run under -race), with a bounds check that the EWMA of {0,1} samples
// can never leave [0,1].
func TestHedgeGovernorWinRateConcurrency(t *testing.T) {
	t.Parallel()
	g := inferhedge.NewGovernor()
	models := []string{"shared", "shared", "solo-a", "solo-b"}

	var wg sync.WaitGroup
	for i, model := range models {
		wg.Add(1)
		go func(model string, won bool) {
			defer wg.Done()
			for range 500 {
				g.RecordOutcome(model, won)
				g.ModelWinRate(model)
			}
		}(model, i%2 == 0)
	}
	wg.Wait()

	for _, model := range []string{"shared", "solo-a", "solo-b"} {
		rate := g.ModelWinRate(model)
		if rate < 0 || rate > 1 {
			t.Fatalf("win rate for %q = %v, want within [0,1]", model, rate)
		}
	}
	if got := g.ModelWinRate("never-hedged"); got != inferhedge.WinRateUnknown {
		t.Fatalf("untouched model rate = %v, want unknown", got)
	}
}

// TestHedgeGovernorTryAcquireAtomicBudget is the P1-2 regression: N
// concurrent acquirers race for a fleet-wide budget of ONE (idle alternative,
// zero fleet idle slots → floor of one). Because the budget read and the
// increment are one mutex hold, exactly one may win — the old
// check-then-increment split let every racer observe the same free slot and
// launch past the cap. Releasing the slot then restores exactly one
// acquisition.
func TestHedgeGovernorTryAcquireAtomicBudget(t *testing.T) {
	t.Parallel()
	g := inferhedge.NewGovernor()
	in := inferhedge.Inputs{
		IdleAlternativeExists: true,
		FleetIdleSlots:        0, // hedgeGlobalBudget → floor of 1
	}

	const acquirers = 16
	var wg sync.WaitGroup
	results := make([]bool, acquirers)
	verdicts := make([]inferhedge.Verdict, acquirers)
	for i := range acquirers {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			verdicts[i], results[i] = g.TryAcquire("model-a", in)
		}(i)
	}
	wg.Wait()

	acquired := 0
	for i := range acquirers {
		if results[i] {
			acquired++
			if verdicts[i] != inferhedge.Allow {
				t.Fatalf("acquired slot carried verdict %v, want allow", verdicts[i])
			}
		} else if verdicts[i] != inferhedge.SuppressGlobalBudget {
			t.Fatalf("loser verdict = %v, want suppress_global_budget", verdicts[i])
		}
	}
	if acquired != 1 {
		t.Fatalf("%d concurrent acquirers won a budget of 1, want exactly 1", acquired)
	}
	if got := g.ActiveCount(); got != 1 {
		t.Fatalf("activeHedges=%d after the race, want 1", got)
	}

	// A failure path releases the slot; the budget is whole again.
	g.Resolve()
	if verdict, ok := g.TryAcquire("model-a", in); !ok || verdict != inferhedge.Allow {
		t.Fatalf("acquire after release = (%v, %v), want (allow, true)", verdict, ok)
	}
}

// TestHedgeGovernorMinSampleFloor is the P1-1 lockout regression: a model
// whose FIRST hedge loses seeds its EWMA at 0, and the old immediate floor
// then suppressed every future hedge — no launches, no fresh outcomes, no
// recovery, for the lifetime of the server. The floor now waits for
// hedgeWinRateMinSamples recorded outcomes before it may bind.
func TestHedgeGovernorMinSampleFloor(t *testing.T) {
	g := inferhedge.NewGovernor()
	in := inferhedge.Inputs{
		IdleAlternativeExists: true,
		FleetIdleSlots:        80, // budget 20: never the binding rule here
	}

	// One losing race: EWMA 0, but only one sample — hedging continues.
	g.RecordOutcome("model-a", false)
	for i := g.ModelSamples("model-a"); i < inferhedge.WinRateMinSamples; i++ {
		verdict, ok := g.TryAcquire("model-a", in)
		if verdict != inferhedge.Allow || !ok {
			t.Fatalf("sample %d: verdict=(%v, %v), want allow below the min-sample floor", i, verdict, ok)
		}
		g.Resolve()
		g.RecordOutcome("model-a", false)
	}

	// At hedgeWinRateMinSamples all-loss outcomes the floor binds.
	if verdict, ok := g.TryAcquire("model-a", in); verdict != inferhedge.SuppressWinRate || ok {
		t.Fatalf("verdict=(%v, %v) at the sample floor, want (suppress_win_rate, false)", verdict, ok)
	}
}

// TestHedgeGovernorExplorationEscape pins the P1-1 recovery path: while a
// model is win-rate suppressed, every hedgeWinRateExploreInterval-th
// evaluation converts to an exploration allow whose recorded outcome
// refreshes the EWMA — so a regime change can lift the model back over the
// floor instead of the suppression being permanent.
func TestHedgeGovernorExplorationEscape(t *testing.T) {
	g := inferhedge.NewGovernor()
	in := inferhedge.Inputs{
		IdleAlternativeExists: true,
		FleetIdleSlots:        80,
	}

	// Establish a suppressed model: min-sample count of pure losses.
	for range inferhedge.WinRateMinSamples {
		g.RecordOutcome("model-a", false)
	}

	// One full cadence: the first interval-1 evaluations stay suppressed,
	// the interval-th converts to an exploration allow.
	for i := 1; i < inferhedge.WinRateExploreInterval; i++ {
		if verdict, ok := g.TryAcquire("model-a", in); verdict != inferhedge.SuppressWinRate || ok {
			t.Fatalf("evaluation %d: verdict=(%v, %v), want suppressed until the exploration slot", i, verdict, ok)
		}
	}
	verdict, ok := g.TryAcquire("model-a", in)
	if verdict != inferhedge.Allow || !ok {
		t.Fatalf("evaluation %d: verdict=(%v, %v), want the exploration allow", inferhedge.WinRateExploreInterval, verdict, ok)
	}

	// The exploration hedge resolves as a WIN and refreshes the EWMA; wins
	// on subsequent exploration hedges compound until the model clears the
	// floor and normal hedging resumes.
	g.Resolve()
	g.RecordOutcome("model-a", true)
	for g.ModelWinRate("model-a") < inferhedge.WinRateFloor {
		for {
			verdict, ok := g.TryAcquire("model-a", in)
			if ok {
				if verdict != inferhedge.Allow {
					t.Fatalf("acquired exploration hedge carried verdict %v", verdict)
				}
				break
			}
		}
		g.Resolve()
		g.RecordOutcome("model-a", true)
	}
	if verdict, ok := g.TryAcquire("model-a", in); verdict != inferhedge.Allow || !ok {
		t.Fatalf("verdict=(%v, %v) after recovery over the floor, want (allow, true)", verdict, ok)
	}
}
