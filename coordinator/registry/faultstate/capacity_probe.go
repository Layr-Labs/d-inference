package faultstate

import (
	"time"
)

// CapacityProbe captures a connection's binding before the reservation claim.
// Claim validates it under the gate lock and follows any intervening migration.
// It owns no lock while pending, and the claim never invokes the wait observer.
type CapacityProbe[C comparable] struct {
	owner *Manager[C]
	ref   gateRef[C]
}

func (r *Manager[C]) PrepareCapacityProbe(p *Session[C], id string) CapacityProbe[C] {
	return CapacityProbe[C]{owner: r, ref: r.probeGateRef(p, id)}
}

func (p CapacityProbe[C]) Claim(model string, now time.Time) bool {
	return p.owner.claimCapacityProbeRef(p.ref, model, now)
}

func (p CapacityProbe[C]) View() View[C] { return View[C]{owner: p.owner, p: p.ref.p, g: p.ref.g} }

func (v View[C]) HasCapacityCooldown() bool { return v.g.hasPairState(gateFlagCapacityCooldown) }

// tryClaimCapacityProbe claims the single half-open probe for an EXPIRED
// cooldown entry, called by the reservation commit (under p.mu, in both
// commit modes) at the moment a request is actually bound to the pair. The
// check and the claim are ONE gate.mu section, so concurrent commits for the
// same identity serialize here even though the commit itself no longer holds
// the registry write lock: the first to reserve the pair claims the probe and
// every later one sees the fresh claim.
//
// Returns false when the pair's gate is CLOSED right now — inside its TTL, or
// expired with another request's probe claim still fresh — so the caller
// rejects the reservation instead of leaking a second probe through the
// post-expiry window. Returns true (a no-op) for a pair with no cooldown entry
// — the overwhelmingly common case, one lock-free flag load — and true after
// claiming an unclaimed or stale slot. nil-safe (a bare Provider has no gate).
//
// The claim is a mutation, so it goes through lockGate like the recorders: a
// rebind that lands between loading p.gate and taking the lock moves the
// cooldown entry to the session's new gate, and a claim made on the old
// (emptied) gate would find no entry and admit — a leaked probe through a
// cooled pair. lockGate sees p.gate moved and re-resolves. Lock order: the
// caller holds p.mu; gatesMu (on a re-resolve) and gate.mu nest under it.
func (r *Manager[C]) TryClaimCapacityProbe(p *Session[C], sessionID, model string, now time.Time) bool {
	return r.PrepareCapacityProbe(p, sessionID).Claim(model, now)
}

// probeGateRef resolves the gate the commit's probe claim targets: the
// connected Provider's cached p.gate (no lock), remembering p so lockGate can
// tell when the session rebound between this load and the lock. A Provider
// that was never registered (bare test objects) falls back to the session
// lookup; nil resolves to no gate.
func (r *Manager[C]) probeGateRef(p *Session[C], sessionID string) gateRef[C] {
	if p == nil {
		return gateRef[C]{}
	}
	if g := p.gate.Load(); g != nil {
		return gateRef[C]{g: g.resolve(), p: p, session: p.id}
	}
	return r.lookupSessionGateRef(sessionID)
}

// claimCapacityProbeRef is tryClaimCapacityProbe on an already-resolved ref
// (split out so a test can interpose a rebind between resolution and claim).
func (r *Manager[C]) claimCapacityProbeRef(ref gateRef[C], model string, now time.Time) bool {
	ref, has := r.refHasPairState(ref, gateFlagCapacityCooldown)
	if !has {
		return true
	}
	hold := r.lockGate(ref, "capacity_probe")
	if hold.g == nil {
		return true
	}
	// Release directly, not via hold.unlock(): the caller holds p.mu (and
	// r.mu in global commit mode), and the observer's DogStatsD emit must
	// never run inside those sections. The probe's gate wait is therefore not
	// reported; the recorders' waits on the same gates are.
	defer hold.g.mu.Unlock()
	return hold.g.tryClaimCapacityProbeLocked(model, now)
}

// tryClaimCapacityProbeLocked is the check-and-claim itself. Caller holds
// g.mu (lockGate has validated the gate is the session's current one).
func (g *gateState) tryClaimCapacityProbeLocked(model string, now time.Time) bool {
	e, ok := g.capacityCooldowns[model]
	if !ok {
		return true
	}
	if now.Before(e.expiry) {
		return false
	}
	if e.probeAt.IsZero() || !now.Before(e.probeAt.Add(capacityProbeOutcomeWindow)) {
		e.probeAt = now
		return true
	}
	return false
}
