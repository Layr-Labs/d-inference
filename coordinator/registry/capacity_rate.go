package registry

import (
	"time"
)

// capacityRatePenaltyFor reads the connected provider's cached gate, confirmed
// against its current binding, for the candidate's cost input.
func (r *Registry) capacityRatePenaltyFor(p *Provider, model string, now time.Time) (penaltyMs, rate float64) {
	view := r.gateViewOf(p)
	for {
		penaltyMs, rate = view.g.capacityRatePenalty(model, now)
		if !view.moved() {
			return penaltyMs, rate
		}
	}
}

// CapacityRejectRate reports the identity's windowed capacity rejection rate.
func (r *Registry) CapacityRejectRate(providerID, modelID string) (rate float64, samples int) {
	return r.gates.CapacityRejectRate(providerID, modelID)
}
