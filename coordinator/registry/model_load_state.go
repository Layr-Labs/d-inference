package registry

import "time"

func (r *Registry) expirePendingModelLoads(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.modelLoads.Expire(now)
}

// providerHasPendingLoad is read while the caller holds registry ownership.
func (r *Registry) providerHasPendingLoad(providerID string) bool {
	return r.modelLoads.HasProvider(providerID)
}

// ClearIneligiblePendingModelLoads releases warm-pool reservations whose
// provider/model pair no longer passes the command-side catalog and capability
// gate. Runtime-policy revocation calls this after capability reconciliation so
// stale protected loads cannot consume the global pending-load budget.
func (r *Registry) ClearIneligiblePendingModelLoads(providerID string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, ok := r.providers[providerID]
	if !ok {
		return 0
	}
	p.mu.Lock()
	defer p.mu.Unlock()

	var ineligible []string
	for _, modelID := range r.modelLoads.Models(providerID) {
		if r.providerCanAcquireCatalogModelLocked(p, modelID) {
			continue
		}
		ineligible = append(ineligible, modelID)
	}
	return r.modelLoads.RemoveModels(providerID, ineligible)
}

// ClearPendingModelLoad removes a pending model load entry after a terminal
// load_model_status response.
func (r *Registry) ClearPendingModelLoad(providerID, modelID string) time.Duration {
	r.mu.Lock()
	started := r.modelLoads.Complete(providerID, modelID)
	r.mu.Unlock()
	if started.IsZero() {
		return 0
	}
	return time.Since(started)
}

func (r *Registry) PendingModelLoadDuration(providerID, modelID string) time.Duration {
	r.mu.RLock()
	started := r.modelLoads.Observe(providerID, modelID).StartedAt
	r.mu.RUnlock()
	if started.IsZero() {
		return 0
	}
	return time.Since(started)
}

// HasPendingModelLoad reports whether an unexpired coordinator-issued
// load_model command exists for exactly this provider/model pair. It lets the
// WebSocket boundary reject unsolicited load_model_status messages before
// allowing them to mutate warm-model state.
func (r *Registry) HasPendingModelLoad(providerID, modelID string) bool {
	r.mu.RLock()
	status := r.modelLoads.Observe(providerID, modelID)
	r.mu.RUnlock()
	return status.Pending && time.Now().Before(status.ExpiresAt)
}

// backoffPendingModelLoad retains registry serialization around the leaf transaction.
func (r *Registry) backoffPendingModelLoad(providerID, modelID string, backoff time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.modelLoads.Backoff(providerID, modelID, backoff)
}

func (r *Registry) pendingModelLoadCount(now time.Time) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.modelLoads.Count(now)
}
