package api

import "sync"

// Hedge governor — the admission half of Routing v2 Phase 4: insurance that
// cannot amplify an overload.
//
// Production evidence this exists to answer: the measured spread failure is
// occupancy HERDING, not lack of diversity — idle loaded boxes coexisted with
// 100% of the gpt-oss cancels (registry/ttft_shadow.go), while recent timeout
// route rows carried candidate counts of 86-401. Hedges launched into that
// herd make it strictly worse: each hedge occupies a second slot for the same
// request, occupancy rises, TTFT estimates degrade, more requests look slow,
// more hedges launch — the classic congestion-collapse spiral. Every rule
// below is a brake on that loop; a hedge is pure insurance and insurance must
// never outrank real demand.
//
// The verdict is a pure function of a point-in-time inputs snapshot so it can
// be tested exhaustively and attributed in telemetry: each suppression
// increments routing.hedge_governor_suppressed tagged with the verdict string
// and logs speculative_backup_suppressed. The mutable half — the global
// active-hedge counter and per-model win-rate EWMAs — lives in hedgeGovernor;
// dispatch wiring (inc on launch, dec on resolve, snapshot into inputs) lives
// in runSpeculative and dispatch_plan_wiring.go governorVerdictForBackup.

const (
	// hedgeFleetIdleHeadroomSlots is the minimum fleet-wide idle-slot count
	// that substitutes for a model-scoped idle alternative. When
	// IdleAlternativeExists is false the hedge would land on a box that is
	// already doing something; that is tolerable only while the fleet keeps
	// real headroom, because the displaced capacity can be absorbed
	// elsewhere. Two slots — not one — so a hedge can never consume the LAST
	// idle slot, which belongs to the next primary request (primaries
	// outrank insurance, always).
	hedgeFleetIdleHeadroomSlots = 2

	// hedgeGlobalBudgetFraction caps concurrent hedges fleet-wide as a
	// fraction of current idle slots. At 1/4, even if every in-flight hedge
	// loses its race and squats its slot for a full TTFT, three quarters of
	// the idle headroom remains for primary demand — the spiral cannot close
	// because hedge load is bounded by a shrinking resource: as utilization
	// rises, idle slots fall, the budget falls with them, and the hedge rate
	// collapses toward zero exactly when the fleet needs relief (the
	// routingsim overload scenario in the plan). Expressed as a division so
	// the budget is integer math on slot counts.
	hedgeGlobalBudgetDivisor = 4

	// hedgeWinRateFloor suppresses hedging for a model whose hedges almost
	// never beat the primary. A win rate persistently below 10% means the
	// primaries are fine and the hedges are ~pure waste heat — nine losing
	// dispatches buying one marginal win. Below the floor the model backs
	// off to no-hedge until fresh outcomes (recordHedgeOutcome at race
	// resolution in runSpeculative) lift the EWMA back over it.
	hedgeWinRateFloor = 0.10

	// hedgeWinRateAlpha is the EWMA weight of each new hedge outcome,
	// matching the repo-wide recency/smoothness balance (registry
	// ttftEWMAAlpha = 0.2): one anomalous race cannot flip a model across
	// the floor, but a real regime change shows within a handful of hedges.
	hedgeWinRateAlpha = 0.2

	// hedgeWinRateUnknown is the sentinel for "no hedge outcome recorded yet
	// for this model". Unknown passes the floor: a model must be allowed to
	// hedge before it can have a win rate, otherwise the floor would
	// permanently fail closed for every new model.
	hedgeWinRateUnknown = -1.0
)

// hedgeGovernorInputs is a point-in-time snapshot of everything the verdict
// reads. Kept as plain locals (not registry types) so the decision is
// snapshot-consistent and independently testable; governorVerdictForBackup
// (dispatch_plan_wiring.go) populates it under the registry's existing
// locks.
type hedgeGovernorInputs struct {
	// idleAlternativeExists: an idle-loaded eligible provider for this model
	// is routable right now (the registry's IdleAlternativeExists machinery)
	// — the hedge has somewhere genuinely spare to land.
	idleAlternativeExists bool
	// modelQueueDepth: requests currently queued for this model. Queued
	// demand is a primary that could not even start; it outranks insurance
	// unconditionally.
	modelQueueDepth int
	// activeHedges: hedges currently in flight fleet-wide (the governor's
	// own counter).
	activeHedges int
	// fleetIdleSlots: idle slots across the whole fleet right now.
	fleetIdleSlots int
	// modelWinRate: this model's hedge win-rate EWMA in [0,1], or
	// hedgeWinRateUnknown when no outcome has been recorded.
	modelWinRate float64
}

// hedgeVerdict is the governor's decision. Non-allow values name the FIRST
// failing rule in precedence order so telemetry attributes each suppression
// to one cause.
type hedgeVerdict int

const (
	hedgeAllow hedgeVerdict = iota
	// hedgeSuppressQueued: the model has queued demand; queued primaries
	// outrank insurance.
	hedgeSuppressQueued
	// hedgeSuppressNoIdleCapacity: no idle alternative for the model and no
	// fleet-wide idle headroom — the hedge would displace real work.
	hedgeSuppressNoIdleCapacity
	// hedgeSuppressGlobalBudget: the fleet-wide concurrent-hedge budget is
	// spent.
	hedgeSuppressGlobalBudget
	// hedgeSuppressWinRate: this model's hedges persistently lose; back off
	// to no-hedge.
	hedgeSuppressWinRate
)

// String is the bounded verdict vocabulary used as the metric tag and log
// field.
func (v hedgeVerdict) String() string {
	switch v {
	case hedgeAllow:
		return "allow"
	case hedgeSuppressQueued:
		return "suppress_queued"
	case hedgeSuppressNoIdleCapacity:
		return "suppress_no_idle_capacity"
	case hedgeSuppressGlobalBudget:
		return "suppress_global_budget"
	case hedgeSuppressWinRate:
		return "suppress_win_rate"
	default:
		return "unknown"
	}
}

// hedgeGlobalBudget is the fleet-wide cap on concurrently running hedges:
// fleetIdleSlots / hedgeGlobalBudgetDivisor, with a floor of one whenever ANY
// idle capacity exists (a model-scoped idle alternative counts even when the
// fleet-wide count reads zero — the signals are sampled independently). With
// no idle capacity at all the budget is zero: an overloaded fleet runs no
// insurance.
func hedgeGlobalBudget(fleetIdleSlots int, idleAlternativeExists bool) int {
	if fleetIdleSlots <= 0 && !idleAlternativeExists {
		return 0
	}
	budget := fleetIdleSlots / hedgeGlobalBudgetDivisor
	if budget < 1 {
		budget = 1
	}
	return budget
}

// hedgeGovernorVerdict applies the launch rules in precedence order and
// returns the first failure (or allow). Pure function of the snapshot; the
// zero-value inputs suppress (no idle capacity), so a wiring bug that forgets
// to populate the snapshot fails closed instead of hedging blind.
func hedgeGovernorVerdict(in hedgeGovernorInputs) hedgeVerdict {
	if in.modelQueueDepth > 0 {
		return hedgeSuppressQueued
	}
	if !in.idleAlternativeExists && in.fleetIdleSlots < hedgeFleetIdleHeadroomSlots {
		return hedgeSuppressNoIdleCapacity
	}
	if in.activeHedges >= hedgeGlobalBudget(in.fleetIdleSlots, in.idleAlternativeExists) {
		return hedgeSuppressGlobalBudget
	}
	if in.modelWinRate != hedgeWinRateUnknown && in.modelWinRate < hedgeWinRateFloor {
		return hedgeSuppressWinRate
	}
	return hedgeAllow
}

// hedgeGovernor owns the mutable feedback state behind the verdict: the
// global active-hedge counter and the per-model win-rate EWMAs. One instance
// per Server; every method is safe for concurrent use from the dispatch
// goroutines that launch and resolve hedges.
type hedgeGovernor struct {
	mu           sync.Mutex
	activeHedges int
	// winRates holds per-model hedge win-rate EWMAs in [0,1]. A model absent
	// from the map has recorded no outcome (hedgeWinRateUnknown). Bounded by
	// the served-model catalog, so no eviction is needed.
	winRates map[string]float64
}

func newHedgeGovernor() *hedgeGovernor {
	return &hedgeGovernor{winRates: make(map[string]float64)}
}

// noteHedgeLaunched increments the global in-flight hedge count. Called
// exactly once per launched backup dispatch (runSpeculative), before the
// dispatch is sent, so the budget check and the increment cannot admit more
// hedges than the budget under concurrency.
func (g *hedgeGovernor) noteHedgeLaunched() {
	g.mu.Lock()
	g.activeHedges++
	g.mu.Unlock()
}

// noteHedgeResolved decrements the in-flight count when a hedge finishes for
// any reason — win, loss, cancellation, or provider failure. Clamped at zero
// so a double-resolve bug degrades to a slightly generous budget instead of a
// negative count that would disable the budget entirely.
func (g *hedgeGovernor) noteHedgeResolved() {
	g.mu.Lock()
	if g.activeHedges > 0 {
		g.activeHedges--
	}
	g.mu.Unlock()
}

// activeHedgeCount snapshots the in-flight count for the verdict inputs.
func (g *hedgeGovernor) activeHedgeCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.activeHedges
}

// recordHedgeOutcome folds one resolved hedge race into the model's win-rate
// EWMA: won means the hedge produced the committed first content. The first
// sample seeds the average directly (the repo's RecordLatency pattern) so a
// model's early rate reflects real outcomes rather than a synthetic prior.
func (g *hedgeGovernor) recordHedgeOutcome(model string, won bool) {
	sample := 0.0
	if won {
		sample = 1.0
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	prior, ok := g.winRates[model]
	if !ok {
		g.winRates[model] = sample
		return
	}
	g.winRates[model] = prior*(1-hedgeWinRateAlpha) + sample*hedgeWinRateAlpha
}

// modelWinRate snapshots the model's EWMA for the verdict inputs;
// hedgeWinRateUnknown when no outcome has been recorded.
func (g *hedgeGovernor) modelWinRate(model string) float64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	rate, ok := g.winRates[model]
	if !ok {
		return hedgeWinRateUnknown
	}
	return rate
}
