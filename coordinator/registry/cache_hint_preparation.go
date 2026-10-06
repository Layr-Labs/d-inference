package registry

import "time"

// CacheHintPreparation is the detached input to the pre-scan cache query. The
// caller copies an eligible route key while holding registry ownership, then
// releases that ownership before querying provider capabilities.
type CacheHintPreparation struct {
	Query    CacheHintQuerier
	Mode     string
	RouteKey []byte
}

func (p CacheHintPreparation) WantsHints(plan CachePlan) bool {
	return p.eligible(p.Query != nil, plan)
}

func (p CacheHintPreparation) eligible(available bool, plan CachePlan) bool {
	return available && p.Mode == CacheRoutingOn && plan.Present() && len(p.RouteKey) > 0
}

type CacheHintResult struct {
	Hints         map[string]CacheRoutingHint
	Opportunity   CacheOpportunity
	SelectionMode string
}

func (p CacheHintPreparation) Prepare(model string, plan CachePlan, now time.Time) CacheHintResult {
	var result CacheHintResult
	if p.WantsHints(plan) {
		result.Hints, result.Opportunity = p.Query.Query(model, plan, p.RouteKey, p.Mode, now)
	}
	if plan.Present() && p.Mode == CacheRoutingOn {
		result.SelectionMode = "active"
	}
	return result
}

func (result CacheHintResult) Apply(pr *PendingRequest) {
	pr.cacheRoutingHints = result.Hints
	pr.CacheOpportunity = result.Opportunity
	pr.CacheSelectionMode = result.SelectionMode
	pr.CacheSelectionTier = ""
	pr.CacheSelectionDiscountMs = 0
	pr.CacheSelectionEstimatedTTFTSavedMs = 0
	pr.CacheSelectionSelected = false
	pr.cacheSelectionPredictedTokens = 0
}
