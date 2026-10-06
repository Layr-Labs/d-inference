package cachefunnel

// Planning is what cache planning concluded for the request body.
type Planning uint8

const (
	// PlanningNotObserved: no planning decision was recorded for the request.
	PlanningNotObserved Planning = iota
	PlanningNotEligible
	PlanningPlannerUnavailable
	PlanningGateRefused
	PlanningSampledOut
	PlanningRateLimited
	PlanningFailed
	PlanningEmpty
	PlanningPlanned
)

// Routing is the cache opportunity of one dispatched attempt.
type Routing uint8

const (
	RoutingNotObserved Routing = iota
	RoutingNoRepeat
	RoutingRepeatWithoutHolder
	RoutingHolderUnusableOrUnavailable
	RoutingHolderNotSelected
	RoutingSelected
)

// RoutingFromOpportunity maps the registry's attempt opportunity reason. An
// unrecognized value stays unobserved instead of being guessed into a bucket.
func RoutingFromOpportunity(reason string) Routing {
	switch reason {
	case "no_repeat_observed":
		return RoutingNoRepeat
	case "repeat_without_holder":
		return RoutingRepeatWithoutHolder
	case "holder_evidence_unusable", "holder_unavailable", "holder_no_positive_credit":
		return RoutingHolderUnusableOrUnavailable
	case "holder_not_selected":
		return RoutingHolderNotSelected
	case "selected", "selected_near_tie":
		return RoutingSelected
	default:
		return RoutingNotObserved
	}
}

// Lookup is the cache lookup outcome the provider reported with its usage.
type Lookup uint8

const (
	LookupNotReported Lookup = iota
	LookupHit
	LookupMiss
	LookupSkip
)

// LookupFromUsageOutcome maps a validated provider usage cache outcome.
func LookupFromUsageOutcome(outcome string) Lookup {
	switch outcome {
	case "hit":
		return LookupHit
	case "miss_absent", "miss_corrupt":
		return LookupMiss
	case "skipped_capacity", "skipped_cost", "skipped_policy":
		return LookupSkip
	default:
		return LookupNotReported
	}
}

// Tokens is a token quantity that may not have been observed.
type Tokens struct {
	Count int
	Known bool
}

func KnownTokens(count int) Tokens { return Tokens{Count: count, Known: true} }

// observed turns a negative count into unknown, so a Record and the
// aggregates built from it can never disagree about what was counted.
func (t Tokens) observed() Tokens {
	if t.Count < 0 {
		return Tokens{}
	}
	return t
}

// Attempt is the routing evidence of one attempt handed to a provider.
type Attempt struct {
	Routing Routing
	// Scoped: the provider received a cache scope, so it could look up and save.
	Scoped bool
	// Predicted is what the coordinator expected the chosen provider to restore.
	Predicted Tokens
}

// Completion is what the completing attempt's provider reported.
type Completion struct {
	Lookup Lookup
	// Reused is the provider-reported cached-token count.
	Reused Tokens
}
