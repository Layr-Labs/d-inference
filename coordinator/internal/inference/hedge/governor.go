package hedge

import (
	"sync"
)

// hedgeGovernor owns the mutable feedback state behind the verdict: the
// global active-hedge counter, the per-model win-rate EWMAs with their sample
// counts, and the per-model exploration cadence. One instance per Server;
// every method is safe for concurrent use from the dispatch goroutines that
// launch and resolve hedges.
type Governor struct {
	mu           sync.Mutex
	activeHedges int
	// winRates holds per-model hedge win-rate EWMAs in [0,1]. A model absent
	// from the map has recorded no outcome (hedgeWinRateUnknown). Bounded by
	// the served-model catalog, so no eviction is needed.
	winRates map[string]float64
	// winSamples counts recorded outcomes per model; the win-rate floor is
	// enforced only at hedgeWinRateMinSamples or more.
	winSamples map[string]int
	// suppressedSinceExplore counts consecutive win-rate suppressions per
	// model since the last exploration hedge; at
	// hedgeWinRateExploreInterval it resets and the evaluation converts to
	// an exploration allow.
	suppressedSinceExplore map[string]int
}

func NewGovernor() *Governor {
	return &Governor{
		winRates:               make(map[string]float64),
		winSamples:             make(map[string]int),
		suppressedSinceExplore: make(map[string]int),
	}
}

// tryAcquireHedge computes the launch verdict for one speculative backup AND,
// on allow, claims its global budget slot — atomically, under one mutex hold.
// The caller supplies the registry-side snapshot fields; the governor fills
// activeHedges, the model's win-rate EWMA/sample count, and the exploration
// flag from its own state. The read-check-increment being ONE operation is
// the point: concurrent slow requests can no longer all observe the same free
// budget and launch past the fleet-wide cap during a burst.
//
// A win-rate suppression advances the model's exploration cadence; every
// hedgeWinRateExploreInterval-th one converts to an exploration allow (the
// verdict is re-derived with exploreNow set, so the earlier rules still
// bind). acquired reports whether a slot was claimed; every acquired hedge
// MUST be released exactly once via noteHedgeResolved, whatever becomes of
// the dispatch.
func (g *Governor) TryAcquire(model string, in Inputs) (verdict Verdict, acquired bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	in.ActiveHedges = g.activeHedges
	in.ModelWinRate = WinRateUnknown
	if rate, ok := g.winRates[model]; ok {
		in.ModelWinRate = rate
	}
	in.ModelWinRateSamples = g.winSamples[model]
	in.ExploreNow = false
	verdict = Evaluate(in)
	if verdict == SuppressWinRate {
		g.suppressedSinceExplore[model]++
		if g.suppressedSinceExplore[model] >= WinRateExploreInterval {
			g.suppressedSinceExplore[model] = 0
			in.ExploreNow = true
			verdict = Evaluate(in)
		}
	}
	if verdict != Allow {
		return verdict, false
	}
	g.activeHedges++
	return Allow, true
}

// noteHedgeResolved decrements the in-flight count when a hedge finishes for
// any reason — win, loss, cancellation, or provider failure. Clamped at zero
// so a double-resolve bug degrades to a slightly generous budget instead of a
// negative count that would disable the budget entirely.
func (g *Governor) Resolve() {
	g.mu.Lock()
	if g.activeHedges > 0 {
		g.activeHedges--
	}
	g.mu.Unlock()
}

// activeHedgeCount snapshots the in-flight count for the verdict inputs.
func (g *Governor) ActiveCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.activeHedges
}

// recordHedgeOutcome folds one resolved hedge race into the model's win-rate
// EWMA and bumps its sample count: won means the hedge produced the committed
// first content. The first sample seeds the average directly (the repo's
// RecordLatency pattern) so a model's early rate reflects real outcomes
// rather than a synthetic prior.
func (g *Governor) RecordOutcome(model string, won bool) {
	sample := 0.0
	if won {
		sample = 1.0
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	g.winSamples[model]++
	prior, ok := g.winRates[model]
	if !ok {
		g.winRates[model] = sample
		return
	}
	g.winRates[model] = prior*(1-WinRateAlpha) + sample*WinRateAlpha
}

// modelWinRate snapshots the model's EWMA for the verdict inputs;
// hedgeWinRateUnknown when no outcome has been recorded.
func (g *Governor) ModelWinRate(model string) float64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	rate, ok := g.winRates[model]
	if !ok {
		return WinRateUnknown
	}
	return rate
}

// ModelSamples reports the evidence count behind the model feedback estimate.
func (g *Governor) ModelSamples(model string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.winSamples[model]
}
