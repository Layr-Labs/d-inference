package cachefunnel

// Reason is the single terminal classification of one request. The order of
// the constants is the lifecycle order and the order of the status response.
type Reason uint8

const (
	// Planning stage: the request never received a cache plan.
	NotEligible Reason = iota
	PlannerUnavailable
	GateRefused
	SampledOut
	RateLimited
	PlanFailed
	PlanEmpty
	PlanningUnobserved

	// Dispatch stage: no provider was ever handed the request.
	CancelledBeforeDispatch
	ErroredBeforeDispatch

	// Routing stage: the request was dispatched without a selected holder.
	RoutingUnobserved
	NoRepeatObserved
	RepeatWithoutHolder
	HolderUnusableOrUnavailable
	HolderNotSelected

	// Provider stage: a holder was selected, or the provider reported reuse.
	SelectedWithoutScope
	CancelledAfterDispatch
	ErroredAfterDispatch
	SelectedOutcomeUnknown
	SelectedSkip
	SelectedMiss
	HitWithoutSelection
	Hit

	reasonCount
)

var reasonNames = [reasonCount]string{
	NotEligible:                 "not_eligible",
	PlannerUnavailable:          "planner_unavailable",
	GateRefused:                 "gate_refused",
	SampledOut:                  "sampled_out",
	RateLimited:                 "rate_limited",
	PlanFailed:                  "plan_failed",
	PlanEmpty:                   "plan_empty",
	PlanningUnobserved:          "planning_unobserved",
	CancelledBeforeDispatch:     "cancelled_before_dispatch",
	ErroredBeforeDispatch:       "errored_before_dispatch",
	RoutingUnobserved:           "routing_unobserved",
	NoRepeatObserved:            "no_repeat_observed",
	RepeatWithoutHolder:         "repeat_without_holder",
	HolderUnusableOrUnavailable: "holder_unusable_or_unavailable",
	HolderNotSelected:           "holder_not_selected",
	SelectedWithoutScope:        "selected_without_scope",
	CancelledAfterDispatch:      "cancelled_after_dispatch",
	ErroredAfterDispatch:        "errored_after_dispatch",
	SelectedOutcomeUnknown:      "selected_outcome_unknown",
	SelectedSkip:                "selected_skip",
	SelectedMiss:                "selected_miss",
	HitWithoutSelection:         "hit_without_selection",
	Hit:                         "hit",
}

func (r Reason) String() string {
	if r >= reasonCount {
		return "invalid"
	}
	return reasonNames[r]
}
