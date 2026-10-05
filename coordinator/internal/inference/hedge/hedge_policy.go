package hedge

const (
	// hedgeFleetIdleHeadroomSlots is the minimum fleet-wide idle-slot count
	// that substitutes for a model-scoped idle alternative. When
	// IdleAlternativeExists is false the hedge would land on a box that is
	// already doing something; that is tolerable only while the fleet keeps
	// real headroom, because the displaced capacity can be absorbed
	// elsewhere. Two slots — not one — so a hedge can never consume the LAST
	// idle slot, which belongs to the next primary request (primaries
	// outrank insurance, always).
	FleetIdleHeadroomSlots = 2

	// hedgeGlobalBudgetFraction caps concurrent hedges fleet-wide as a
	// fraction of current idle slots. At 1/4, even if every in-flight hedge
	// loses its race and squats its slot for a full TTFT, three quarters of
	// the idle headroom remains for primary demand — the spiral cannot close
	// because hedge load is bounded by a shrinking resource: as utilization
	// rises, idle slots fall, the budget falls with them, and the hedge rate
	// collapses toward zero exactly when the fleet needs relief (the
	// routingsim overload scenario in the plan). Expressed as a division so
	// the budget is integer math on slot counts.
	GlobalBudgetDivisor = 4

	// hedgeWinRateFloor suppresses hedging for a model whose hedges almost
	// never beat the primary. A win rate persistently below 10% means the
	// primaries are fine and the hedges are ~pure waste heat — nine losing
	// dispatches buying one marginal win. Below the floor the model backs
	// off to no-hedge until fresh outcomes (recordHedgeOutcome at race
	// resolution in runSpeculative, including the periodic exploration
	// hedges below) lift the EWMA back over it.
	WinRateFloor = 0.10

	// hedgeWinRateMinSamples is the minimum number of recorded hedge
	// outcomes before the win-rate floor is enforced. The floor's
	// justification is ECONOMIC — nine losing dispatches buying one marginal
	// win — and that arithmetic needs statistical footing: a single unlucky
	// first race seeds the EWMA at 0 and, because outcomes are recorded only
	// for LAUNCHED hedges, a floor enforced immediately would lock the model
	// out of hedging forever (no launches → no fresh outcomes → no
	// recovery). Below this count the win rate passes and the model keeps
	// sampling.
	WinRateMinSamples = 8

	// hedgeWinRateExploreInterval bounds a win-rate lockout: every Nth
	// win-rate-suppressed evaluation (per model) converts to an allow — an
	// exploration hedge whose recorded outcome refreshes the EWMA, so a
	// model whose hedges started losing can prove a regime change and earn
	// normal hedging back. At 1-in-16 the exploration cost is negligible
	// (~6% of the suppressed volume) while recovery stays within a handful
	// of slow-request bursts; without it the suppression is permanent for
	// the lifetime of the server.
	WinRateExploreInterval = 16

	// hedgeWinRateAlpha is the EWMA weight of each new hedge outcome,
	// matching the repo-wide recency/smoothness balance (registry
	// ttftEWMAAlpha = 0.2): one anomalous race cannot flip a model across
	// the floor, but a real regime change shows within a handful of hedges.
	WinRateAlpha = 0.2

	// hedgeWinRateUnknown is the sentinel for "no hedge outcome recorded yet
	// for this model". Unknown passes the floor: a model must be allowed to
	// hedge before it can have a win rate, otherwise the floor would
	// permanently fail closed for every new model.
	WinRateUnknown = -1.0
)

// Inputs is a point-in-time snapshot of everything the verdict
// reads. Kept as plain locals (not registry types) so the decision is
// snapshot-consistent and independently testable; tryAcquireBackupHedge
// (dispatch_plan_wiring.go) populates the registry-side fields under the
// registry's existing locks, and tryAcquireHedge fills the governor-owned
// ones under its own mutex.
type Inputs struct {
	// idleAlternativeExists: an idle-loaded eligible provider for this model
	// is routable right now (the registry's IdleAlternativeExists machinery)
	// — the hedge has somewhere genuinely spare to land.
	IdleAlternativeExists bool
	// modelQueueDepth: requests currently queued for this model. Queued
	// demand is a primary that could not even start; it outranks insurance
	// unconditionally.
	ModelQueueDepth int
	// activeHedges: hedges currently in flight fleet-wide (the governor's
	// own counter).
	ActiveHedges int
	// fleetIdleSlots: idle slots across the whole fleet right now.
	FleetIdleSlots int
	// modelWinRate: this model's hedge win-rate EWMA in [0,1], or
	// hedgeWinRateUnknown when no outcome has been recorded.
	ModelWinRate float64
	// modelWinRateSamples: how many resolved hedge outcomes the EWMA is
	// built on. The win-rate floor is enforced only at
	// hedgeWinRateMinSamples or more (see that constant's WHY).
	ModelWinRateSamples int
	// exploreNow: this evaluation is the model's periodic exploration hedge
	// (every hedgeWinRateExploreInterval-th win-rate suppression) — the
	// win-rate floor is waived for it so the EWMA can be refreshed. Every
	// other rule still applies: exploration is insurance too and must not
	// displace queued primaries or bust the global budget.
	ExploreNow bool
}

// Verdict is the governor's decision. Non-allow values name the FIRST
// failing rule in precedence order so telemetry attributes each suppression
// to one cause.
type Verdict int

const (
	Allow Verdict = iota
	// hedgeSuppressQueued: the model has queued demand; queued primaries
	// outrank insurance.
	SuppressQueued
	// hedgeSuppressNoIdleCapacity: no idle alternative for the model and no
	// fleet-wide idle headroom — the hedge would displace real work.
	SuppressNoIdleCapacity
	// hedgeSuppressGlobalBudget: the fleet-wide concurrent-hedge budget is
	// spent.
	SuppressGlobalBudget
	// hedgeSuppressWinRate: this model's hedges persistently lose; back off
	// to no-hedge.
	SuppressWinRate
)

// String is the bounded verdict vocabulary used as the metric tag and log
// field.
func (v Verdict) String() string {
	switch v {
	case Allow:
		return "allow"
	case SuppressQueued:
		return "suppress_queued"
	case SuppressNoIdleCapacity:
		return "suppress_no_idle_capacity"
	case SuppressGlobalBudget:
		return "suppress_global_budget"
	case SuppressWinRate:
		return "suppress_win_rate"
	default:
		return "unknown"
	}
}

// GlobalBudget is the fleet-wide cap on concurrently running hedges:
// fleetIdleSlots / hedgeGlobalBudgetDivisor, with a floor of one whenever ANY
// idle capacity exists (a model-scoped idle alternative counts even when the
// fleet-wide count reads zero — the signals are sampled independently). With
// no idle capacity at all the budget is zero: an overloaded fleet runs no
// insurance.
func GlobalBudget(FleetIdleSlots int, IdleAlternativeExists bool) int {
	if FleetIdleSlots <= 0 && !IdleAlternativeExists {
		return 0
	}
	budget := FleetIdleSlots / GlobalBudgetDivisor
	if budget < 1 {
		budget = 1
	}
	return budget
}

// Evaluate applies the launch rules in precedence order and
// returns the first failure (or allow). Pure function of the snapshot; the
// zero-value inputs suppress (no idle capacity), so a wiring bug that forgets
// to populate the snapshot fails closed instead of hedging blind.
func Evaluate(in Inputs) Verdict {
	if in.ModelQueueDepth > 0 {
		return SuppressQueued
	}
	if !in.IdleAlternativeExists && in.FleetIdleSlots < FleetIdleHeadroomSlots {
		return SuppressNoIdleCapacity
	}
	if in.ActiveHedges >= GlobalBudget(in.FleetIdleSlots, in.IdleAlternativeExists) {
		return SuppressGlobalBudget
	}
	if in.ModelWinRate != WinRateUnknown &&
		in.ModelWinRateSamples >= WinRateMinSamples &&
		in.ModelWinRate < WinRateFloor &&
		!in.ExploreNow {
		return SuppressWinRate
	}
	return Allow
}
