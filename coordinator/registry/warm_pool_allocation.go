package registry

import "time"

// allocateWarmPoolLoads continues through the ranked candidates after another
// model claimed a provider or a concurrent state change invalidated a choice.
// A tick never issues competing model changes to the same Mac, including in
// observe-only mode. This also addresses the allocation defect described in #922.
func allocateWarmPoolLoads(model string, candidates []warmPoolCandidate, need int, assigned map[string]bool, now time.Time, reserve func([]modelLoadAction, time.Time) []modelLoadAction) []modelLoadAction {
	var actions []modelLoadAction
	for _, candidate := range candidates {
		if len(actions) >= need {
			break
		}
		if assigned[candidate.providerID] {
			continue
		}
		action := modelLoadAction{providerID: candidate.providerID, modelID: model}
		if reserve != nil && len(reserve([]modelLoadAction{action}, now)) == 0 {
			continue
		}
		assigned[candidate.providerID] = true
		actions = append(actions, action)
	}
	return actions
}

// The active controller is the sole planner of unsolicited load_model commands.
// Recheck its eligibility while reserving, including physical load allowance,
// current work, operator inventory and the per-provider pending-load fence.
func (c *warmPoolController) reserveActions(actions []modelLoadAction, now time.Time) []modelLoadAction {
	r := c.registry
	r.mu.Lock()
	defer r.mu.Unlock()
	var reserved []modelLoadAction
	for _, action := range actions {
		p := r.providers[action.providerID]
		if p == nil {
			continue
		}
		p.mu.Lock()
		if r.providerHasWarmModelLocked(p, action.modelID, now) {
			p.mu.Unlock()
			continue
		}
		_, reason := r.warmPoolCandidateReasonLocked(p, action.modelID, now)
		if reason == warmColdEligible {
			key := modelLoadKey{ProviderID: action.providerID, ModelID: action.modelID}
			if r.pendingModelLoads == nil {
				r.pendingModelLoads = make(map[modelLoadKey]time.Time)
			}
			if r.pendingModelLoadStarted == nil {
				r.pendingModelLoadStarted = make(map[modelLoadKey]time.Time)
			}
			r.pendingModelLoads[key] = now.Add(pendingModelLoadTTL)
			r.pendingModelLoadStarted[key] = now
			reserved = append(reserved, action)
		}
		p.mu.Unlock()
	}
	return reserved
}
