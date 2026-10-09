package registry

import "time"

// fleetSampleColdKVEstimates collects one forecast for the sample, not one per
// provider. Only actual slot probes and their pending cold work need estimates;
// an unused on-disk advertisement never justifies scanning its peers.
// No registry lease spans the participant walk or a whole model's donor walk.
func (r *Registry) fleetSampleColdKVEstimates(providers []*Provider, now time.Time) coldKVEstimates {
	var wanted coldKVRequirements
	for _, p := range providers {
		p.mu.Lock()
		if p.BackendCapacity != nil && len(p.BackendCapacity.Slots) > 0 {
			for _, slot := range p.BackendCapacity.Slots {
				wanted.addLocked(p, slot.Model)
			}
			for _, pending := range p.pendingReqs {
				wanted.addLocked(p, pending.Model)
			}
		}
		p.mu.Unlock()
	}
	var estimates coldKVEstimates
	for model, identities := range wanted {
		r.mu.RLock()
		sources := r.providersForModelLocked(model)
		r.mu.RUnlock()
		for _, p := range sources {
			r.mu.RLock()
			if r.providers[p.ID] != p {
				r.mu.RUnlock()
				continue
			}
			p.mu.Lock()
			key, rate := r.observedColdKVRateLocked(p, model, now)
			p.mu.Unlock()
			r.mu.RUnlock()
			if _, needed := identities[key]; rate > 0 && needed {
				if estimates == nil {
					estimates = make(coldKVEstimates)
				}
				estimates[key] = max(estimates[key], rate)
			}
		}
	}
	return estimates
}
