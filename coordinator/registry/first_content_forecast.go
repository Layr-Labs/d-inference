package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

const (
	FirstContentFeasible             = forecast.Feasible
	FirstContentUnknown              = forecast.Unknown
	FirstContentPredictedLate        = forecast.PredictedLate
	firstContentPerformanceFreshness = forecast.PerformanceFreshness
	// A delivery allowance, not a measured network round trip. The conservative
	// forecast allows additional handoff and early decode/detokenization work.
	firstContentConservativeHandoffMs = forecast.ConservativeHandoffMS
)

// FirstContentEstimate distinguishes ranking from advisory deadline evidence.
// Even a credible conservative forecast is not a completion guarantee: the
// provider still performs atomic admission against its current GPU schedule.
type FirstContentEstimate = forecast.Estimate

// firstContentSnapshot is copied under the same provider lock as the physical
// admission snapshot. Missing measurement age remains unknown; heartbeat age
// is never used as a substitute for performance age.
type firstContentSnapshot struct {
	prefillWorkloadRates        []prefillWorkloadRate
	transportMs                 float64
	conservativeTransportMs     float64
	transportAgeMs              int32
	capacityAgeMs               int32
	capacityAcceptedAt          time.Time
	capacitySeq                 uint64
	performanceAgeMs            int32
	evidenceGapAgeMs            int32
	isolatedPrefillTPS          float64
	isolatedPrefillInitialized  bool
	wholeMacBusy                bool
	wholeMacWorkKnown           bool
	otherModelOccupancy         int
	queuedPrefillKnown          bool
	partialPrefillRows          int
	wholeMacServiceMs           float64
	modelLoadMs                 float64
	calibratedWork              firstcontent.Work
	calibratedWorkKnown         bool
	deadlineProfile             *deadlinePerformanceProfile
	contendedPerformanceAgeMs   int32
	contendedPrefillTPS         float64
	calibratedDecodeTPS         float64
	promptWorkContractID        string
	promptWorkArtifactHash      string
	calibratedForecastQualified bool
}

// estimateFirstContent runs after cache proof validation. It never changes
// memory reservations, completion limits, ownership or physical eligibility.
func (r *Registry) estimateFirstContent(c *routingCandidate, s *routingSnapshot, pr *PendingRequest, now time.Time) {
	cacheContractMatches := s.promptWorkContractID != "" &&
		pr.CachePlan.ModelAggregateHash == s.promptWorkArtifactHash && pr.CachePlan.PromptContractID == s.promptWorkContractID
	cacheQualified := cacheContractMatches && r.cacheRouting != nil && pr.CachePlan.Authenticates(r.cacheRouting.generation) &&
		r.cacheRouting.generation.Active() && pr.CachePlan.Present()
	prompt, conservativePrompt := forecast.PromptCounts(pr.EstimatedPromptTokens, pr.FirstContentPromptTokens, pr.PromptWork,
		s.promptWorkArtifactHash, s.promptWorkContractID, pr.CachePlan.PromptTokenCount, cacheQualified)
	request := forecast.Request{Incoming: performance.IncomingWork{RequiresVision: pr.RequiresVision, PromptWork: pr.PromptWork, RequestedMaxTokens: pr.RequestedMaxTokens}, PromptTokens: prompt, UpperBoundTokens: conservativePrompt, Deadline: pr.FirstContentDeadline, FreshAfter: pr.RequireFreshFeasibleAfter, MaxTTFTMS: pr.MaxTTFTMs, Hedge: pr.Hedge, RequireFreshFeasible: pr.RequireFreshFeasible, PlanningHorizon: pr.FirstContentPlanningHorizon}
	if !pr.CachePlan.Present() || cacheContractMatches {
		forecast.CacheBenefit{Tokens: c.firstContentCachedTokens, Weight: c.firstContentCacheWeight,
			RestoreMS: c.firstContentRestoreMs, ExpiresAt: c.firstContentCacheExpiresAt}.Apply(&request, now)
	}
	evidence := firstContentForecastEvidence(s, prompt)
	result := forecast.Evaluate(&evidence, request, now)
	s.calibratedForecastQualified = result.Calibrated
	c.firstContentEvidenceQualified = result.EvidenceQualified
	c.firstContent = result.Estimate
}

// firstContentCandidateAllowed retains unknown evidence as a bounded fallback.
// The existing optional hard ceiling applies only to credible late forecasts.
func firstContentCandidateAllowed(c *routingCandidate, pr *PendingRequest) bool {
	return forecast.Allows(c.firstContent, forecast.Request{Hedge: pr.Hedge,
		RequireFreshFeasible: pr.RequireFreshFeasible, MaxTTFTMS: pr.MaxTTFTMs},
		c.snapshot.wholeMacBusy || c.snapshot.totalPending > 0)
}

// preferFirstContentCandidates ranks qualified evidence first. Candidates
// whose only gap is evidence they have been idle too long to renew stay beside
// feasible peers (first_content_exploration.go); without feasible candidates
// the unknown fallback is unchanged.
func preferFirstContentCandidates(pool []*routingCandidate) []*routingCandidate {
	for _, c := range pool {
		if c.firstContent.Status == FirstContentFeasible {
			return preferRoutingCandidates(pool, func(c *routingCandidate) bool {
				return c.firstContent.Status == FirstContentFeasible || firstContentEvidenceExplorable(c)
			})
		}
	}
	return preferRoutingCandidates(pool, func(c *routingCandidate) bool { return c.firstContent.Status == FirstContentUnknown })
}
