package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/faultstate"
)

// budgetClampedFor reads and confirms a faultstate.View for the routing
// snapshot's admission check. The caller holds p.mu.
func (r *Registry) budgetClampedFor(p *Provider, model string, heartbeatAt time.Time, rawBudgetRemaining int64, budgetReported bool, now time.Time) bool {
	view := r.gateViewOf(p)
	for {
		clamped := view.g.BudgetClampActive(model, heartbeatAt, rawBudgetRemaining, budgetReported, now)
		if !view.moved() {
			return clamped
		}
	}
}

// capacityRatePenaltyFor reads and confirms a faultstate.View for candidate cost.
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

// dispatchLoadCooled resolves the pair through faultstate.Manager.DispatchLoadCooled.
// The scan instead reads the cached binding through faultstate.View.
func (r *Registry) dispatchLoadCooled(providerID, modelID string, now time.Time) bool {
	return r.faults.DispatchLoadCooled(providerID, modelID, now)
}

// breakerOpen resolves the session through faultstate.Manager.BreakerOpen.
// The scan instead reads the cached binding through faultstate.View.BreakerOpenAt.
func (r *Registry) breakerOpen(providerID string, now time.Time) bool {
	return r.faults.BreakerOpen(providerID, now)
}

// capacityCooled resolves the pair through faultstate.Manager.CapacityCooled.
// The scan instead reads the cached binding through faultstate.View.CapacityCooled.
func (r *Registry) capacityCooled(providerID, modelID string, now time.Time) bool {
	return r.faults.CapacityCooled(providerID, modelID, now)
}

// capacityRatePenalty resolves the pair through faultstate.Manager.CapacityRatePenalty.
// The scan instead confirms its cached view through capacityRatePenaltyFor.
func (r *Registry) capacityRatePenalty(providerID, modelID string, now time.Time) (penaltyMs, rate float64) {
	return r.faults.CapacityRatePenalty(providerID, modelID, now)
}

// budgetClamped resolves the pair through faultstate.Manager.BudgetClamped.
// The scan instead confirms its cached view through budgetClampedFor.
func (r *Registry) budgetClamped(providerID, modelID string, heartbeatAt time.Time, rawBudgetRemaining int64, budgetReported bool, now time.Time) bool {
	return r.faults.BudgetClamped(providerID, modelID, heartbeatAt, rawBudgetRemaining, budgetReported, now)
}
