package registry

import "time"

// QuickFirstContentCapacityForRequest is the read-only preflight for a fully
// scoped request. It shares ownership, traits, cache proof, physical admission
// and first-content forecasting with dispatch, without claiming capacity.
// Unknown forecasts keep hasTTFT false so callers cannot reject them as late.
func (r *Registry) QuickFirstContentCapacityForRequest(model string, pr *PendingRequest) (candidateCount, capacityRejections, modelTooLarge int, bestTTFT time.Duration, hasTTFT bool) {
	if pr == nil {
		return
	}
	// Copy only routing inputs; PendingRequest owns mutexes/channels and must
	// never be copied by value. A ceiling is inspected below, not used to erase
	// physically eligible candidates from preflight's counters.
	query := &PendingRequest{RequestID: "first-content-preflight", Model: model,
		EstimatedPromptTokens: pr.EstimatedPromptTokens, FirstContentPromptTokens: pr.FirstContentPromptTokens,
		RequestedMaxTokens: pr.RequestedMaxTokens, Traits: pr.Traits, RequiresVision: pr.RequiresVision,
		FirstContentDeadline: pr.FirstContentDeadline, MinDecodeTPS: pr.MinDecodeTPS,
		SelfRouteOnly: pr.SelfRouteOnly, PreferOwner: pr.PreferOwner, OwnerAccountID: pr.OwnerAccountID,
		AllowedProviderSerials: pr.AllowedProviderSerials, ExcludedProviderIDs: pr.ExcludedProviderIDs,
		CachePlan: pr.CachePlan, PromptWork: pr.PromptWork}
	if query.RequestedMaxTokens <= 0 {
		query.RequestedMaxTokens = defaultRequestedMaxTokens
	}
	r.prepareRequestCacheHints(model, query)
	r.mu.RLock()
	defer r.mu.RUnlock()
	_, scan := r.selectBestCandidateLockedFull(model, query)
	candidateCount, capacityRejections, modelTooLarge = scan.candidateCount, scan.capacityRejections, scan.tooLargeRejections
	for _, c := range scan.pool {
		if c.firstContent.Status == FirstContentUnknown {
			return candidateCount, capacityRejections, modelTooLarge, 0, false
		}
		estimate := time.Duration(c.firstContent.ConservativeMs * float64(time.Millisecond))
		if !hasTTFT || estimate < bestTTFT {
			bestTTFT, hasTTFT = estimate, true
		}
	}
	return
}
