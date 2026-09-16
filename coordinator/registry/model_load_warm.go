package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// MarkModelWarm adds a model to the provider's WarmModels list if not already
// present. Called when load_model_status:succeeded arrives before the next
// heartbeat, so the scheduler sees the provider as warm during queue drain.
func (r *Registry) MarkModelWarm(providerID, modelID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.RUnlock()
		return
	}
	p.mu.Lock()
	if !r.providerServesCatalogModelLocked(p, modelID) {
		p.mu.Unlock()
		r.mu.RUnlock()
		return
	}
	defer func() {
		p.mu.Unlock()
		r.mu.RUnlock()
	}()
	for _, wm := range p.WarmModels {
		if wm == modelID {
			return // already warm
		}
	}
	p.WarmModels = append(p.WarmModels, modelID)
	p.CurrentModel = modelID

	// Inject a synthetic "idle" slot into BackendCapacity so the scheduler
	// sees the model as warm. Without this, the scheduler only checks
	// BackendCapacity.Slots (not WarmModels) for Swift providers, and a
	// stale snapshot without the new model's slot would treat it as cold
	// until the next heartbeat arrives.
	//
	// We only add/update the new model's slot and leave existing slots
	// untouched — the provider may have multiple model slots loaded
	// simultaneously (maxModelSlots defaults to 3). The next heartbeat
	// will provide the authoritative slot list.
	if p.BackendCapacity != nil {
		found := false
		for i, slot := range p.BackendCapacity.Slots {
			if slot.Model == modelID {
				p.BackendCapacity.Slots[i].State = "idle"
				found = true
				break
			}
		}
		if !found {
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
				Model: modelID,
				State: "idle",
			})
		}
	}
}
