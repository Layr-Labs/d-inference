package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
)

type pendingModelLoadSendAttempt struct {
	provider *Provider
	timing   pendingload.Reservation
}

func (r *Registry) modelLoadSendStillPending(action modelLoadAction) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.modelLoadSendStillPendingLocked(action)
}

// Caller holds r.mu. Reservation ownership is frozen when the planner reserves
// the action, before any earlier command in its batch can block on the writer.
func (r *Registry) modelLoadSendStillPendingLocked(action modelLoadAction) bool {
	key := pendingload.Key{ProviderID: action.ProviderID, ModelID: action.ModelID}
	reservation, pending := r.pendingLoads.Lookup(key)
	attempt := action.reservation
	return pending && r.providers[action.ProviderID] == attempt.provider &&
		reservation == attempt.timing
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
	key := pendingload.Key{ProviderID: action.ProviderID, ModelID: action.ModelID}
	if !r.modelLoadSendStillPendingLocked(action) {
		r.mu.Unlock()
		return
	}
	if p := action.reservation.provider; p != nil {
		p.mu.Lock()
		now := time.Now()
		p.recordDeadlineActivityLocked(now)
		p.warmLifecycleLocked().BackoffUntil(now.Add(pendingModelLoadMemoryBackoff))
		p.mu.Unlock()
	}
	r.pendingLoads.Drop(key)
	r.mu.Unlock()
	r.RequestWarmPoolTrigger()
}
