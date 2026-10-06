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

// Tier is the cache tier a reported hit was restored from.
type Tier uint8

const (
	TierNotReported Tier = iota
	TierMemory
	TierSSD
)

// TierFromUsage maps a validated provider usage cache tier.
func TierFromUsage(tier string) Tier {
	switch tier {
	case "memory":
		return TierMemory
	case "ssd":
		return TierSSD
	default:
		return TierNotReported
	}
}

// String is the tier's metric label; a request with no hit tier reads "none".
func (t Tier) String() string {
	switch t {
	case TierMemory:
		return "memory"
	case TierSSD:
		return "ssd"
	default:
		return "none"
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
	// Predicted is the cached-token count the coordinator expected the chosen
	// provider to restore: the credited holder's anchor depth, comparable with
	// Completion.Reused. Unknown when no holder was selected.
	Predicted Tokens
}

// Completion is what the completing attempt's provider reported.
type Completion struct {
	Lookup Lookup
	// Tier is the cache tier of a reported hit.
	Tier Tier
	// Reused is the provider-reported cached-token count: the prompt tokens
	// billed at the cache-read rate.
	Reused Tokens
	// PrefillSaved is the provider-reported prefill the hit skipped. It never
	// exceeds Reused; the difference was restored and then recomputed.
	PrefillSaved Tokens
	// ProviderPrompt is the provider-reported prompt-token count, the same
	// source as Reused and PrefillSaved.
	ProviderPrompt Tokens
}

// hitTier is the tier of a reported hit, and TierNotReported for every other
// outcome, so a tier never counts for a request that reused nothing.
func (c Completion) hitTier() Tier {
	if c.Lookup != LookupHit {
		return TierNotReported
	}
	return c.Tier
}
