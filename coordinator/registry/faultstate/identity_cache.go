package faultstate

import (
	"time"
)

// disconnectedStableID caches a provider's stable identity at Disconnect time so
// the trailing pending-request ErrorCh flush can still resolve it.
type disconnectedStableID struct {
	id string
	at time.Time
	// binding is shared only with short-lived recorder refs, not Provider.
	// Identity migration updates it under the old gate's mutex before reset.
	binding *disconnectedGateBinding
}

// disconnectedStableIDTTL bounds how long a disconnected provider's cached stable
// identity stays resolvable — long enough for the synchronous pending-request flush
// and any immediately-trailing terminal, short enough to stay tiny.
const disconnectedStableIDTTL = 2 * time.Minute

// rememberDisconnectedStableIDLocked caches a provider's stable identity keyed by
// its about-to-be-removed session id. Caller holds gatesMu for writing.
func (r *Manager[C]) rememberDisconnectedStableIDLocked(sessionID, stableID string, disconnectedAt time.Time) {
	if r.disconnectedStableIDs == nil {
		r.disconnectedStableIDs = make(map[string]disconnectedStableID)
	}
	if len(r.disconnectedStableIDs) > 4096 {
		cutoff := r.now().Add(-disconnectedStableIDTTL)
		for k, v := range r.disconnectedStableIDs {
			if v.at.Before(cutoff) {
				delete(r.disconnectedStableIDs, k)
			}
		}
	}
	r.disconnectedStableIDs[sessionID] = disconnectedStableID{id: stableID, at: disconnectedAt, binding: newDisconnectedGateBinding(stableID)}
}
