package routeplan

import "github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"

// FunnelPlanning folds the planning decision reasons into the reuse funnel's
// planning stages. An outcome this package cannot name stays unobserved.
func FunnelPlanning(reason CachePlanningDecisionReason) cachefunnel.Planning {
	switch reason {
	case CachePlanningOff, CachePlanningIneligible, CachePlanningLoweringUnsupported, CachePlanningColdOnly:
		return cachefunnel.PlanningNotEligible
	case CachePlanningDependenciesUnavailable, CachePlanningArtifactMissing, CachePlanningArtifactPending,
		CachePlanningArtifactFailed, CachePlanningArtifactInvalid, CachePlanningPreloadNotReady:
		return cachefunnel.PlanningPlannerUnavailable
	case CachePlanningSampledOut:
		return cachefunnel.PlanningSampledOut
	case CachePlanningThrottled:
		return cachefunnel.PlanningRateLimited
	case CachePlanningSidecarError, CachePlanningInvalidPlan:
		return cachefunnel.PlanningFailed
	case CachePlanningNoBoundaries:
		return cachefunnel.PlanningEmpty
	case CachePlanningPlanned:
		return cachefunnel.PlanningPlanned
	default:
		return cachefunnel.PlanningNotObserved
	}
}

// CountedPromptTokens is the tokenizer's exact count when this decision
// produced one, which it does even for a prompt too short to carry a boundary.
func (d CachePlanDecision) CountedPromptTokens() cachefunnel.Tokens {
	if d.PromptWork == nil || d.PromptWork.PromptTokens <= 0 {
		return cachefunnel.Tokens{}
	}
	return cachefunnel.KnownTokens(d.PromptWork.PromptTokens)
}
