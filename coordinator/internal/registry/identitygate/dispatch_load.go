package identitygate

import (
	"time"
)

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
func (r *Directory) RecordDispatchLoadFailure(providerID, modelID string) bool {
	return r.RecordDispatchLoadFailureUntil(r.gateForSession(providerID), modelID, time.Time{})
}

// RecordDispatchLoadFailureUntil records a load failure with its retry deadline.
// A zero deadline uses the ordinary dispatch-load cooldown.
func (r *Directory) RecordDispatchLoadFailureUntil(ref Reference, modelID string, retryAfter time.Time) bool {
	hold := r.lockGate(ref, "dispatch_load_failure")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return false
	}
	now := r.now()
	expiry, active := g.dispatchLoadCooldowns[modelID]
	active = active && now.Before(expiry)
	if retryAfter.IsZero() {
		retryAfter = now.Add(dispatchLoadCooldownTTL)
	}
	g.dispatchLoadCooldowns[modelID] = retryAfter
	g.updatedLocked(now)
	return !active
}

// ClearDispatchLoadCooldown removes the cool-down for one provider-model pair
// (called when the pair serves a request successfully — it can load after all).
// Runs at request completion; takes only the identity's gate.mu.
func (r *Directory) ClearDispatchLoadCooldown(providerID, modelID string) {
	ref, has := r.PrepareDispatchLoadClear(r.lookupSessionGateRef(providerID))
	if !has {
		return // nothing to clear — the common case, one lock-free flag load
	}
	r.ClearDispatchLoadCooldownRef(ref, modelID, NewRetryBudget())
}

// PrepareDispatchLoadClear validates the lock-free empty-state shortcut before
// a completion attempts to clear the identity's dispatch-load fault.
func (r *Directory) PrepareDispatchLoadClear(ref Reference) (Reference, bool) {
	return r.refHasPairState(ref, gateFlagDispatchLoad)
}

// ClearDispatchLoadCooldownRef applies the prepared completion and reports the
// identity it reached. A vanished no-insert reference remains a no-op.
func (r *Directory) ClearDispatchLoadCooldownRef(ref Reference, modelID string, budget RetryBudget) View {
	hold := r.lockGateWithBudget(ref, "dispatch_load_clear", budget)
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return View{}
	}

	delete(g.dispatchLoadCooldowns, modelID)
	g.updatedLocked(r.now())
	return View{directory: r, g: g}
}

// dispatchLoadCooled is read-only and nil-safe, with a lock-free empty fast path.
func (g *State) dispatchLoadCooled(modelID string, now time.Time) bool {
	if !g.hasPairState(gateFlagDispatchLoad) {
		return false
	}
	g = g.lockResolved()
	expiry, ok := g.dispatchLoadCooldowns[modelID]
	g.mu.Unlock()
	return ok && now.Before(expiry)
}
