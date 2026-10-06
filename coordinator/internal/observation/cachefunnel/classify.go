package cachefunnel

type classification struct {
	planning   Planning
	planned    bool
	dispatched bool
	completed  bool
	cancelled  bool
	routing    Routing
	scoped     bool
	lookup     Lookup
}

func classify(c classification) Reason {
	// A reported hit is the one outcome showing reuse happened, so it outranks
	// every loss reason, including a missing plan.
	if c.completed && c.lookup == LookupHit {
		if c.routing == RoutingSelected {
			return Hit
		}
		return HitWithoutSelection
	}
	if !c.planned {
		return classifyUnplanned(c)
	}
	if !c.dispatched {
		return endedBeforeDispatch(c.cancelled)
	}
	if c.routing != RoutingSelected {
		return unselectedReason(c.routing)
	}
	return classifySelected(c)
}

func classifyUnplanned(c classification) Reason {
	switch c.planning {
	case PlanningNotEligible:
		return NotEligible
	case PlanningPlannerUnavailable:
		return PlannerUnavailable
	case PlanningGateRefused:
		return GateRefused
	case PlanningSampledOut:
		return SampledOut
	case PlanningRateLimited:
		return RateLimited
	case PlanningFailed:
		return PlanFailed
	case PlanningEmpty:
		return PlanEmpty
	}
	// Either nothing was recorded, or "planned" was recorded for a body the
	// request was not dispatched with.
	if c.dispatched {
		return PlanningUnobserved
	}
	return endedBeforeDispatch(c.cancelled)
}

func endedBeforeDispatch(cancelled bool) Reason {
	if cancelled {
		return CancelledBeforeDispatch
	}
	return ErroredBeforeDispatch
}

func unselectedReason(routing Routing) Reason {
	switch routing {
	case RoutingNoRepeat:
		return NoRepeatObserved
	case RoutingRepeatWithoutHolder:
		return RepeatWithoutHolder
	case RoutingHolderUnusableOrUnavailable:
		return HolderUnusableOrUnavailable
	case RoutingHolderNotSelected:
		return HolderNotSelected
	default:
		return RoutingUnobserved
	}
}

func classifySelected(c classification) Reason {
	if !c.scoped {
		return SelectedWithoutScope
	}
	if !c.completed {
		if c.cancelled {
			return CancelledAfterDispatch
		}
		return ErroredAfterDispatch
	}
	switch c.lookup {
	case LookupMiss:
		return SelectedMiss
	case LookupSkip:
		return SelectedSkip
	default:
		return SelectedOutcomeUnknown
	}
}
