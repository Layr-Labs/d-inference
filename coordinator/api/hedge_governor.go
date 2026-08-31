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
// active-hedge counter and per-model win-rate EWMAs — lives in hedgeGovernor,
// whose tryAcquireHedge computes the verdict AND claims the budget slot under
// ONE mutex hold; dispatch wiring (acquire on launch, release on resolve,
// registry snapshot into inputs) lives in runSpeculative and
// dispatch_plan_wiring.go tryAcquireBackupHedge.

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
	// resolution in runSpeculative, including the periodic exploration
	// hedges below) lift the EWMA back over it.
	hedgeWinRateFloor = 0.10

	// hedgeWinRateMinSamples is the minimum number of recorded hedge
	// outcomes before the win-rate floor is enforced. The floor's
	// justification is ECONOMIC — nine losing dispatches buying one marginal
	// win — and that arithmetic needs statistical footing: a single unlucky
	// first race seeds the EWMA at 0 and, because outcomes are recorded only
	// for LAUNCHED hedges, a floor enforced immediately would lock the model
	// out of hedging forever (no launches → no fresh outcomes → no
	// recovery). Below this count the win rate passes and the model keeps
	// sampling.
	hedgeWinRateMinSamples = 8

	// hedgeWinRateExploreInterval bounds a win-rate lockout: every Nth
	// win-rate-suppressed evaluation (per model) converts to an allow — an
	// exploration hedge whose recorded outcome refreshes the EWMA, so a
	// model whose hedges started losing can prove a regime change and earn
	// normal hedging back. At 1-in-16 the exploration cost is negligible
	// (~6% of the suppressed volume) while recovery stays within a handful
	// of slow-request bursts; without it the suppression is permanent for
	// the lifetime of the server.
	hedgeWinRateExploreInterval = 16

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
// snapshot-consistent and independently testable; tryAcquireBackupHedge
// (dispatch_plan_wiring.go) populates the registry-side fields under the
// registry's existing locks, and tryAcquireHedge fills the governor-owned
// ones under its own mutex.
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
	// modelWinRateSamples: how many resolved hedge outcomes the EWMA is
	// built on. The win-rate floor is enforced only at
	// hedgeWinRateMinSamples or more (see that constant's WHY).
	modelWinRateSamples int
	// exploreNow: this evaluation is the model's periodic exploration hedge
	// (every hedgeWinRateExploreInterval-th win-rate suppression) — the
	// win-rate floor is waived for it so the EWMA can be refreshed. Every
	// other rule still applies: exploration is insurance too and must not
	// displace queued primaries or bust the global budget.
	exploreNow bool
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
	if in.modelWinRate != hedgeWinRateUnknown &&
		in.modelWinRateSamples >= hedgeWinRateMinSamples &&
		in.modelWinRate < hedgeWinRateFloor &&
		!in.exploreNow {
		return hedgeSuppressWinRate
	}
	return hedgeAllow
}

// hedgeGovernor owns the mutable feedback state behind the verdict: the
// global active-hedge counter, the per-model win-rate EWMAs with their sample
// counts, and the per-model exploration cadence. One instance per Server;
// every method is safe for concurrent use from the dispatch goroutines that
// launch and resolve hedges.
type hedgeGovernor struct {
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

func newHedgeGovernor() *hedgeGovernor {
	return &hedgeGovernor{
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
func (g *hedgeGovernor) tryAcquireHedge(model string, in hedgeGovernorInputs) (verdict hedgeVerdict, acquired bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	in.activeHedges = g.activeHedges
	in.modelWinRate = hedgeWinRateUnknown
	if rate, ok := g.winRates[model]; ok {
		in.modelWinRate = rate
	}
	in.modelWinRateSamples = g.winSamples[model]
	in.exploreNow = false
	verdict = hedgeGovernorVerdict(in)
	if verdict == hedgeSuppressWinRate {
		g.suppressedSinceExplore[model]++
		if g.suppressedSinceExplore[model] >= hedgeWinRateExploreInterval {
			g.suppressedSinceExplore[model] = 0
			in.exploreNow = true
			verdict = hedgeGovernorVerdict(in)
		}
	}
	if verdict != hedgeAllow {
		return verdict, false
	}
	g.activeHedges++
	return hedgeAllow, true
}

// acquireHedgeUngoverned claims a budget slot for a hedge admitted OUTSIDE
// the verdict rules — the capacity-SILENT legacy escape in
// tryAcquireBackupHedge, where every governor input is meaningless and the
// verdict is definitionally allow. This is load ACCOUNTING, not a budget-
// check bypass: the legacy hedge is really in flight, so capacity-aware
// requests must see it against their budget. Released exactly once via
// noteHedgeResolved, like any acquired hedge.
func (g *hedgeGovernor) acquireHedgeUngoverned() {
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
// EWMA and bumps its sample count: won means the hedge produced the committed
// first content. The first sample seeds the average directly (the repo's
// RecordLatency pattern) so a model's early rate reflects real outcomes
// rather than a synthetic prior.
func (g *hedgeGovernor) recordHedgeOutcome(model string, won bool) {
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
