package registry

import (
	"time"
)

// BudgetClampActive reports whether the (provider, model) pair's token budget
// is currently clamped for admission. Exposed for tests and observability; the
// routing hot path reads the cached p.faultSession directly.
func (r *Registry) BudgetClampActive(providerID, modelID string) bool {
	p := r.sessionProvider(providerID)
	if p == nil {
		return false
	}
	heartbeatAt, rawRemaining, budgetReported := providerBudgetSnapshot(p, modelID)
	return r.budgetClamped(providerID, modelID, heartbeatAt, rawRemaining, budgetReported, time.Now())
}

// providerReportsTokenBudget reports whether the provider's CURRENT backend
// snapshot carries a token budget for the model (the arming-time input to
// budgetClampEntry.budgetReported). A missing provider (the reject often races
// the disconnect that caused it) or a missing/budgetless slot reads false —
// the sticky-or in recordBudgetClampLocked keeps an identity's demonstrated
// reporting from being downgraded by such a race. Takes p.mu; the caller must
// not hold a gate.mu (lock order p.mu → gate.mu).
func providerReportsTokenBudget(p *Provider, modelID string) bool {
	if p == nil {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.BackendCapacity == nil {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == modelID {
			return slot.ActiveTokenBudgetMax > 0
		}
	}
	return false
}

// providerBudgetSnapshot reads the pair's live budget snapshot — the heartbeat
// freshness anchor, the raw headroom (max - used - queued, unclamped), and
// whether the current capacity report carries a budget for the model at all.
// A missing provider or a missing/budgetless slot reads zero/false. Takes
// p.mu; the caller must not hold a gate.mu (lock order p.mu → gate.mu).
func providerBudgetSnapshot(p *Provider, modelID string) (heartbeatAt time.Time, rawRemaining int64, budgetReported bool) {
	if p == nil {
		return time.Time{}, 0, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	heartbeatAt = p.LastHeartbeat
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == modelID {
				rawRemaining = slot.ActiveTokenBudgetMax - slot.ActiveTokenBudgetUsed - slot.QueuedTokenBudget
				budgetReported = slot.ActiveTokenBudgetMax > 0
				break
			}
		}
	}
	return heartbeatAt, rawRemaining, budgetReported
}
