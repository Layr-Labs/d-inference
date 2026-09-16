package registry

import "time"

func (r *Registry) reservePendingModelLoads(actions []modelLoadAction, now time.Time) []modelLoadAction {
	if len(actions) == 0 {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	reserved := actions[:0]
	for _, action := range actions {
		if p, ok := r.providers[action.providerID]; ok {
			p.mu.Lock()
			eligible := r.providerCanAcquireCatalogModelLocked(p, action.modelID)
			p.mu.Unlock()
			if !eligible {
				continue
			}
		}
		// Check per-provider (not just per-key) to prevent concurrent
		// heartbeat goroutines from reserving the same idle provider
		// for different models.
		if !r.modelLoads.Reserve(action.providerID, action.modelID, now) {
			continue
		}
		reserved = append(reserved, action)
	}
	return reserved
}

func (r *Registry) sendModelLoadActions(actions []modelLoadAction) {
	for _, action := range actions {
		if err := r.SendLoadModel(action.providerID, action.modelID); err != nil {
			r.logger.Warn("failed to trigger model swap",
				"provider_id", action.providerID,
				"model_id", action.modelID,
				"error", err,
			)
			r.ClearPendingModelLoad(action.providerID, action.modelID)
		}
	}
}
