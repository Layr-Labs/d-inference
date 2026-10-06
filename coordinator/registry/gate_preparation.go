package registry

import "time"

func (r *Registry) recordCapacityReject(providerID, modelID string, deratePair, armClamp bool) bool {
	if providerID == "" || modelID == "" {
		return false
	}
	budgetReported := false
	if armClamp {
		budgetReported = providerReportsTokenBudget(r.sessionProvider(providerID), modelID)
	}
	return r.gates.RecordCapacityRejectProjected(providerID, modelID, deratePair, armClamp, budgetReported)
}

func (r *Registry) RecordCapacityAcceptObserved(providerID, modelID string, observedAt time.Time, countRateOutcome bool) bool {
	ref, needsBudget, ok := r.gates.PrepareCapacityAccept(providerID, modelID, countRateOutcome)
	if !ok {
		return false
	}
	var heartbeatAt time.Time
	var rawRemaining int64
	var budgetReported bool
	if needsBudget {
		heartbeatAt, rawRemaining, budgetReported = providerBudgetSnapshot(r.sessionProvider(providerID), modelID)
	}
	return r.gates.ApplyCapacityAccept(ref, modelID, observedAt, countRateOutcome, heartbeatAt, rawRemaining, budgetReported)
}

func (r *Registry) bindStableFaultKey(p *Provider, stableID string) {
	if p == nil {
		return
	}
	r.gates.Bind(p.gateSession, stableID, p.Version)
}
