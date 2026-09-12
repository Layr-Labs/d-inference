package registry

import "sync/atomic"

// disconnectedGateBinding is a cache-owned identity redirect shared with
// recorder refs. It retains only an immutable key, never a disconnected
// Provider or its request/connection state. The cache's existing TTL bounds
// its lifetime; refs may keep it alive only while an outcome is in flight.
type disconnectedGateBinding struct {
	key atomic.Pointer[string]
}

func newDisconnectedGateBinding(key string) *disconnectedGateBinding {
	binding := &disconnectedGateBinding{}
	binding.store(key)
	return binding
}

func (binding *disconnectedGateBinding) store(key string) {
	binding.key.Store(&key)
}

func (binding *disconnectedGateBinding) load() string {
	if key := binding.key.Load(); key != nil {
		return *key
	}
	return ""
}

// retargetDisconnectedGateBindingsLocked moves cached session identities with
// their fault state. Caller holds gatesMu and the source gate's mu, so a
// cached ref either records before the migration or detects the redirect
// after acquiring the source gate. Keep the original disconnect time: it is
// both the cache TTL anchor and the version-reset ordering signal.
func (r *Registry) retargetDisconnectedGateBindingsLocked(oldKey, newKey string) {
	for sessionID, cached := range r.disconnectedStableIDs {
		if cached.id != oldKey {
			continue
		}
		if cached.binding == nil {
			cached.binding = newDisconnectedGateBinding(oldKey)
		}
		cached.binding.store(newKey)
		cached.id = newKey
		r.disconnectedStableIDs[sessionID] = cached
	}
}
