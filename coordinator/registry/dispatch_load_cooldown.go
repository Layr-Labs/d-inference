package registry

import "time"

// dispatchLoadCooldownTTL is how long routing skips a pair after a dispatch
// load failure — long enough to stop the retry loop, short enough that a
// recovered provider returns on its own.
const dispatchLoadCooldownTTL = 2 * time.Minute

// RecordDispatchLoadFailure puts a provider-model pair on a routing cool-down
// after the provider rejected a dispatch with a load failure. Returns true
// when this call started a new cool-down (false when one was already live),
// so callers can emit metrics without double-counting the retry storm. Lives
// on the provider's stable-identity gate (gate_state.go) so the cool-down
// survives a reconnect within its TTL; takes only gate.mu.
func (r *Registry) RecordDispatchLoadFailure(providerID, modelID string) bool {
	hold := r.lockGate(r.gateForSession(providerID), "dispatch_load_failure")
	defer hold.unlock()
	g := hold.g
	now := time.Now()
	expiry, active := g.dispatchLoadCooldowns[modelID]
	active = active && now.Before(expiry)
	g.dispatchLoadCooldowns[modelID] = now.Add(dispatchLoadCooldownTTL)
	g.updatedLocked(now)
	return !active
}

// ClearDispatchLoadCooldown removes the cool-down for one provider-model pair
// (called when the pair serves a request successfully — it can load after all).
// Runs at request completion; takes only the identity's gate.mu.
func (r *Registry) ClearDispatchLoadCooldown(providerID, modelID string) {
	ref, has := r.refHasPairState(r.lookupSessionGateRef(providerID), gateFlagDispatchLoad)
	if !has {
		return // nothing to clear — the common case, one lock-free flag load
	}
	hold := r.lockGate(ref, "dispatch_load_clear")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return
	}

	delete(g.dispatchLoadCooldowns, modelID)
	g.updatedLocked(time.Now())
}

// dispatchLoadCooled reports whether routing should skip the pair. Resolves
// the session's gate; the scan uses the cached p.gate directly.
func (r *Registry) dispatchLoadCooled(providerID, modelID string, now time.Time) bool {
	return r.lookupGateForSession(providerID).dispatchLoadCooled(modelID, now)
}

// dispatchLoadCooled is the gate-level check: lock-free "no cooldown on any
// model" fast path, otherwise one short gate.mu section. READ-ONLY (no lazy
// delete). nil-safe.
func (g *gateState) dispatchLoadCooled(modelID string, now time.Time) bool {
	if !g.hasPairState(gateFlagDispatchLoad) {
		return false
	}
	g = g.lockResolved()
	expiry, ok := g.dispatchLoadCooldowns[modelID]
	g.mu.Unlock()
	return ok && now.Before(expiry)
}
