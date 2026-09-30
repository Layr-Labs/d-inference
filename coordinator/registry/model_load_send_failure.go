package registry

import "time"

type pendingModelLoadSendAttempt struct {
	provider  *Provider
	startedAt time.Time
	expiresAt time.Time
}

func (r *Registry) modelLoadSendStillPending(action modelLoadAction) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.modelLoadSendStillPendingLocked(action)
}

// Caller holds r.mu. Reservation ownership is frozen when the planner reserves
// the action, before any earlier command in its batch can block on the writer.
func (r *Registry) modelLoadSendStillPendingLocked(action modelLoadAction) bool {
	key := modelLoadKey{ProviderID: action.providerID, ModelID: action.modelID}
	expiresAt, pending := r.pendingModelLoads[key]
	attempt := action.reservation
	return pending && r.providers[action.providerID] == attempt.provider &&
		r.pendingModelLoadStarted[key] == attempt.startedAt && expiresAt == attempt.expiresAt
}

// A failed command write may precede disconnect, or only time out waiting for
// the writer. Keep this session out of proactive load planning briefly while
// releasing the fleet-wide reservation for other providers. This is separate
// from load failures reported by a provider and does not fence inference. Reuse
// the transient load-failure delay without retaining the global reservation.
// Failed sends own only the exact session and reservation captured before I/O;
// a late error must not cool down or remove a replacement load.
func (r *Registry) failPendingModelLoadSend(action modelLoadAction) {
	r.mu.Lock()
	key := modelLoadKey{ProviderID: action.providerID, ModelID: action.modelID}
	if !r.modelLoadSendStillPendingLocked(action) {
		r.mu.Unlock()
		return
	}
	if p := action.reservation.provider; p != nil {
		p.mu.Lock()
		now := time.Now()
		p.recordDeadlineActivityLocked(now)
		p.modelLoadSendRetryAt = now.Add(pendingModelLoadMemoryBackoff)
		p.mu.Unlock()
	}
	delete(r.pendingModelLoads, key)
	delete(r.pendingModelLoadStarted, key)
	r.mu.Unlock()
	r.RequestWarmPoolTrigger()
}
