package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/faultstate"
	"time"
)

// budgetClampedFor is budgetClampActive on the connected provider's cached
// gate, confirmed against p.faultSession (gateView) — the routing snapshot's admission
// input (snapshotProviderIntoPLockedEx and the preflight), read under p.mu.
func (r *Registry) budgetClampedFor(p *Provider, model string, heartbeatAt time.Time, rawBudgetRemaining int64, budgetReported bool, now time.Time) bool {
	view := r.gateViewOf(p)
	for {
		clamped := view.g.BudgetClampActive(model, heartbeatAt, rawBudgetRemaining, budgetReported, now)
		if !view.moved() {
			return clamped
		}
	}
}

// capacityRatePenaltyFor is capacityRatePenalty on the connected provider's
// cached gate, confirmed against p.faultSession (gateView): the candidate's cost
// input (buildCandidateInto).
func (r *Registry) capacityRatePenaltyFor(p *Provider, model string, now time.Time) (penaltyMs, rate float64) {
	view := r.gateViewOf(p)
	for {
		penaltyMs, rate = view.g.CapacityRatePenalty(model, now)
		if !view.moved() {
			return penaltyMs, rate
		}
	}
}

type gateView struct {
	p *Provider
	g faultstate.View[*Provider]
}

func (r *Registry) gateViewOf(p *Provider) gateView { return gateView{p: p, g: r.gateOf(p)} }

func (v *gateView) moved() bool { return v.g.Moved() }

func (r *Registry) gateOf(p *Provider) faultstate.View[*Provider] {
	if p == nil {
		return r.faults.ViewOf(nil, "")
	}
	return r.faults.ViewOf(&p.faultSession, p.ID)
}

func (r *Registry) ejectionOpenFor(g faultstate.View[*Provider], sid string, nowNS int64) bool {
	return g.EjectionOpenFor(sid, nowNS)
}

// dispatchLoadCooled reports whether routing should skip the pair. Resolves
// the session's gate; the scan uses the cached p.faultSession directly.
func (r *Registry) dispatchLoadCooled(providerID, modelID string, now time.Time) bool {
	return r.faults.DispatchLoadCooled(providerID, modelID, now)
}

// breakerOpen reports whether routing should skip this provider because its
// node-health breaker is OPEN. True iff now is before the open expiry; once
// now >= expiry it returns false so the next request is allowed through as a
// half-open probe. Resolves the session's gate; the scan itself reads the
// cached p.faultSession atomically (gateState.breakerOpenAt) and never comes here.
func (r *Registry) breakerOpen(providerID string, now time.Time) bool {
	return r.faults.BreakerOpen(providerID, now)
}

// capacityCooled resolves the session's gate; the scan uses the cached p.faultSession
// directly.
func (r *Registry) capacityCooled(providerID, modelID string, now time.Time) bool {
	return r.faults.CapacityCooled(providerID, modelID, now)
}

// capacityRatePenalty resolves the session's gate; the scan uses the cached
// p.faultSession through capacityRatePenaltyFor.
func (r *Registry) capacityRatePenalty(providerID, modelID string, now time.Time) (penaltyMs, rate float64) {
	return r.faults.CapacityRatePenalty(providerID, modelID, now)
}

// budgetClamped resolves the session's gate; the scan uses the cached p.faultSession
// through budgetClampedFor.
func (r *Registry) budgetClamped(providerID, modelID string, heartbeatAt time.Time, rawBudgetRemaining int64, budgetReported bool, now time.Time) bool {
	return r.faults.BudgetClamped(providerID, modelID, heartbeatAt, rawBudgetRemaining, budgetReported, now)
}
