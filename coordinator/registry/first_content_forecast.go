package registry

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/firstcontent"
)

const (
	FirstContentFeasible             = "feasible"
	FirstContentUnknown              = "unknown"
	FirstContentPredictedLate        = "predicted_late"
	firstContentFreshness            = 5 * time.Second
	firstContentPerformanceFreshness = 2 * time.Minute
	firstContentFastBandMs           = 100.0
	// A delivery allowance, not a measured network round trip. The conservative
	// forecast allows additional handoff and early decode/detokenization work.
	firstContentHandoffMs             = 150.0
	firstContentConservativeHandoffMs = 1000.0
	firstContentDecodeAllowance       = 33
)

// FirstContentEstimate distinguishes ranking from advisory deadline evidence.
// Even a credible conservative forecast is not a completion guarantee: the
// provider still performs atomic admission against its current GPU schedule.
type FirstContentEstimate struct {
	PredictionSource string  `json:"prediction_source,omitempty"`
	TransportMs      float64 `json:"transport_ms,omitempty"`
	TransportAgeMs   int32   `json:"transport_age_ms"`
	Status           string  `json:"status"`
	Reason           string  `json:"reason,omitempty"`
	ExpectedMs       float64 `json:"expected_ms"`
	ConservativeMs   float64 `json:"conservative_ms"`
	BudgetMs         float64 `json:"budget_ms,omitempty"`
	CapacityAgeMs    int32   `json:"capacity_age_ms"`
	PerformanceAgeMs int32   `json:"performance_age_ms"`
	PromptTokens     int     `json:"prompt_tokens"`
	CachedTokens     float64 `json:"cached_tokens,omitempty"`
	RestoreMs        float64 `json:"restore_ms,omitempty"`
	ServiceMs        float64 `json:"service_ms"`
}

// firstContentSnapshot is copied under the same provider lock as the physical
// admission snapshot. Missing measurement age remains unknown; heartbeat age
// is never used as a substitute for performance age.
type firstContentSnapshot struct {
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
func (r *Registry) estimateFirstContent(c *routingCandidate, pr *PendingRequest, now time.Time) {
	s := &c.snapshot
	e := FirstContentEstimate{Status: FirstContentUnknown, CapacityAgeMs: s.capacityAgeMs,
		PerformanceAgeMs: s.performanceAgeMs, ServiceMs: s.wholeMacServiceMs, TransportMs: s.transportMs, TransportAgeMs: s.transportAgeMs}
	prompt := max(0, pr.EstimatedPromptTokens)
	conservativePrompt := max(prompt, pr.FirstContentPromptTokens)
	if pr.PromptWork != nil && pr.PromptWork.IsQualifiedFor(s.promptWorkArtifactHash, s.promptWorkContractID) {
		prompt, conservativePrompt = pr.PromptWork.PromptTokens, pr.PromptWork.UpperBoundTokens
	}
	cacheContractMatches := s.promptWorkContractID != "" &&
		pr.CachePlan.ModelAggregateHash == s.promptWorkArtifactHash && pr.CachePlan.PromptContractID == s.promptWorkContractID
	if cacheContractMatches && r.cacheRouting != nil && pr.CachePlan.generation != nil &&
		pr.CachePlan.generation == r.cacheRouting.generation && !pr.CachePlan.generation.revoked.Load() && pr.CachePlan.present() {
		prompt, conservativePrompt = pr.CachePlan.PromptTokenCount, pr.CachePlan.PromptTokenCount
	}
	e.PromptTokens = prompt
	if (!pr.CachePlan.present() || cacheContractMatches) && !c.firstContentCacheExpiresAt.IsZero() && now.Before(c.firstContentCacheExpiresAt) {
		e.CachedTokens = min(float64(prompt), c.firstContentCachedTokens) * c.firstContentCacheWeight
		e.RestoreMs = c.firstContentRestoreMs
	}
	prefill := resolvePrefillTPS(s)
	if !finitePositive(prefill) {
		prefill = 1
	}
	decode := resolveEffectiveTPS(s)
	if !finitePositive(decode) {
		decode = 1
	}
	load := s.modelLoadMs
	if !s.modelLoaded && load <= 0 {
		load, _ = slotStatePenalty(s.slotState)
	}
	// Capacity telemetry cannot join individual queued rows to coordinator
	// reservations. Use the larger overlapping total, never their sum.
	ahead := firstContentPrefillAhead(s, prompt)
	competition := 1 + effectiveTPSLoadFactor*float64(s.otherModelOccupancy)
	e.ExpectedMs = firstContentHandoffMs + s.transportMs + load + e.RestoreMs + s.pendingPrefillRestoreMs +
		(ahead+max(0, float64(prompt)-e.CachedTokens))/prefill*1000*competition + 1000/decode
	conservativeRate := prefill
	if s.isolatedPrefillInitialized && finitePositive(s.isolatedPrefillTPS) {
		conservativeRate = min(conservativeRate, s.isolatedPrefillTPS)
	}
	decodeTokens := firstContentDecodeAllowance
	if pr.RequestedMaxTokens > 0 {
		decodeTokens = min(decodeTokens, pr.RequestedMaxTokens)
	}
	// Uncertainty is represented by input/work bounds and explicit delivery
	// allowances. Apply observed throughput directly; do not halve every rate.
	e.ConservativeMs = firstContentConservativeHandoffMs + s.conservativeTransportMs + load + e.RestoreMs + s.pendingPrefillRestoreMs +
		(ahead+max(0, float64(conservativePrompt)-e.CachedTokens))/conservativeRate*1000*competition +
		float64(decodeTokens)/decode*1000
	e.ConservativeMs = max(e.ConservativeMs, e.ExpectedMs)
	s.calibratedForecastQualified = false
	if prediction, age, ok := calibratedFirstContentPrediction(s, pr, conservativePrompt, e.CachedTokens); ok {
		// The error envelope covers engine work. Delivery and proof restore
		// allowances remain explicit, and the request's deadline is unchanged.
		e.ExpectedMs = firstContentHandoffMs + s.transportMs + e.RestoreMs + s.pendingPrefillRestoreMs + prediction.ExpectedMS
		e.ConservativeMs = firstContentConservativeHandoffMs + s.conservativeTransportMs + e.RestoreMs + s.pendingPrefillRestoreMs + prediction.ConservativeMS
		e.ConservativeMs = max(e.ConservativeMs, e.ExpectedMs)
		e.PredictionSource, e.PerformanceAgeMs = "qualified_calibration", age
		s.calibratedForecastQualified = true
	}
	c.firstContentEvidenceQualified = firstContentForecastUnknownReason(s, pr, prompt, true) == ""
	e.Reason = firstContentForecastUnknownReason(s, pr, prompt, false)
	if pr.FirstContentDeadline.IsZero() && pr.MaxTTFTMs <= 0 && (!(pr.Hedge || pr.RequireFreshFeasible) || pr.FirstContentPlanningHorizon <= 0) {
		e.Reason = "no_deadline"
	}
	if e.Reason == "" {
		e.Status = FirstContentFeasible
	}

	if !pr.FirstContentDeadline.IsZero() {
		e.BudgetMs = max(0, float64(pr.FirstContentDeadline.Sub(now))/float64(time.Millisecond))
	} else if pr.MaxTTFTMs > 0 {
		e.BudgetMs = pr.MaxTTFTMs
	} else if (pr.Hedge || pr.RequireFreshFeasible) && pr.FirstContentPlanningHorizon > 0 {
		e.BudgetMs = float64(pr.FirstContentPlanningHorizon) / float64(time.Millisecond)
	}
	if e.Status == FirstContentFeasible && e.ConservativeMs > e.BudgetMs {
		e.Status = FirstContentPredictedLate
	}
	if !finitePositive(e.ExpectedMs) || !finitePositive(e.ConservativeMs) {
		e.Status, e.Reason = FirstContentUnknown, "invalid_forecast"
		e.ExpectedMs, e.ConservativeMs = math.MaxFloat64, math.MaxFloat64
	}
	c.firstContent = e
}

// firstContentForecastUnknownReason is shared by local forecasts and quote
// revalidation. A new quote can refresh request-specific refusal evidence;
// it cannot establish recency or workload matching for historical measurements.
func firstContentForecastUnknownReason(s *routingSnapshot, pr *PendingRequest, prompt int, ignoreRefusalCutoff bool) string {
	switch {
	case !s.hasBackendCapacity:
		return "capacity_missing"
	case s.capacityAgeMs < 0 || time.Duration(s.capacityAgeMs)*time.Millisecond > firstContentFreshness:
		return "capacity_stale"
	case !ignoreRefusalCutoff && !pr.RequireFreshFeasibleAfter.IsZero() && !s.capacityAcceptedAt.After(pr.RequireFreshFeasibleAfter):
		return "capacity_before_refusal"
	case s.calibratedForecastQualified:
		return ""
	case s.performanceAgeMs < 0 || time.Duration(s.performanceAgeMs)*time.Millisecond > firstContentPerformanceFreshness:
		return "performance_age_unknown_or_stale"
	case !s.isolatedPrefillInitialized || !finitePositive(s.isolatedPrefillTPS) || !finitePositive(s.observedDecodeTPS):
		return "performance_missing"
	case pr.RequiresVision:
		return "vision_work_unknown"
	case !s.modelLoaded:
		return "load_work_unknown"
	case !s.wholeMacWorkKnown || s.wholeMacBusy || s.partialPrefillRows > 0:
		return "competing_work_unknown"
	case prompt <= 0:
		return "prompt_unknown"
	default:
		return ""
	}
}

// firstContentCandidateAllowed retains unknown evidence as a bounded fallback.
// The existing optional hard ceiling applies only to credible late forecasts.
func firstContentCandidateAllowed(c *routingCandidate, pr *PendingRequest) bool {
	if pr.Hedge && (c.snapshot.wholeMacBusy || c.snapshot.totalPending > 0) {
		return false
	}
	if pr.RequireFreshFeasible || pr.Hedge {
		return c.firstContent.Status == FirstContentFeasible
	}
	return pr.MaxTTFTMs <= 0 || c.firstContent.Status != FirstContentPredictedLate
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
