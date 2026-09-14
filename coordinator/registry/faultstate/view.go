package faultstate

import "time"

// View reads one published binding. Call Moved after every batch that decides
// dispatch; a true result rebases the view and asks the caller to repeat it.
// Sampling may use the same reads without confirmation.
func (v View[C]) BreakerOpenAt(nowNS int64) bool { return v.g.breakerOpenAt(nowNS) }
func (v View[C]) EjectedAt(nowNS int64) bool     { return v.g.ejectedAt(nowNS) }
func (v View[C]) DispatchLoadCooled(model string, now time.Time) bool {
	return v.g.dispatchLoadCooled(model, now)
}
func (v View[C]) InferenceErrorCooled(model, shape string, now time.Time) bool {
	return v.g.inferenceErrorCooled(model, shape, now)
}
func (v View[C]) CapacityCooled(model string, now time.Time) bool {
	return v.g.capacityCooled(model, now)
}
func (v View[C]) BudgetClampActive(model string, heartbeatAt time.Time, rawRemaining int64, budgetReported bool, now time.Time) bool {
	if v.owner == nil {
		return false
	}
	return v.g.budgetClampActive(v.owner.budgetClampCfg, model, heartbeatAt, rawRemaining, budgetReported, now)
}
func (v View[C]) CapacityRatePenalty(model string, now time.Time) (float64, float64) {
	if v.owner == nil {
		return 0, 0
	}
	return v.g.capacityRatePenalty(v.owner.capacityRateCfg, model, now)
}
func (v View[C]) EjectionOpenFor(stableID string, nowNS int64) bool {
	if v.owner == nil {
		return false
	}
	return v.owner.ejectionOpenFor(v.g, stableID, nowNS)
}

// DisconnectedIdentityTTL bounds the trailing pending-request flush identity.
const DisconnectedIdentityTTL = disconnectedStableIDTTL

func (r *Manager[C]) BreakerOpen(providerID string, now time.Time) bool {
	return r.breakerOpen(providerID, now)
}
func (r *Manager[C]) EjectionOpen(stableID string, now time.Time) bool {
	return r.ejectionOpen(stableID, now)
}
