package faultstate

import (
	"time"
)

// capacityProbeOutcomeWindow is how long a claimed post-expiry probe keeps the
// gate closed to everyone else while its outcome is pending. A reject outcome
// lands within seconds (capacity rejects are immediate); an accept usually
// does too, but on the accept-then-reload path first content can take much
// longer, so this window is deliberately short — it is a LIVENESS bound, not
// the accept deadline: if it lapses before the outcome lands, the next
// reservation may claim a fresh probe (one extra probe per window during a
// genuinely slow load — the box is accepting, so that is acceptable). Its real
// job is that a probe request which DIED before any terminal reached the
// breaker hooks can never wedge the pair closed forever.
const capacityProbeOutcomeWindow = 30 * time.Second

// capacityCooldownEntry is one pair's active (or expired-awaiting-probe)
// cooldown. Fields are written and read ONLY under the identity's gate.mu
// (arm/re-arm in RecordCapacityReject, probe claim in tryClaimCapacityProbe).
type capacityCooldownEntry struct {
	// expiry is when the quarantine TTL lapses and the pair becomes eligible
	// for a single half-open probe.
	expiry time.Time
	// probeAt is when a post-expiry probe was claimed (zero = unclaimed).
	// While the claim is fresh (now < probeAt+capacityProbeOutcomeWindow) the
	// gate stays closed to everyone but the claimed probe.
	probeAt time.Time
}

// CapacityCooldownActive reports whether the (provider, model) pair is
// currently quarantined by the capacity-reject cooldown. Exposed for tests and
// observability.
func (r *Manager[C]) CapacityCooldownActive(providerID, modelID string) bool {
	return r.CapacityCooled(providerID, modelID, r.now())
}

// capacityCooled resolves the session's gate; the scan uses the cached p.gate
// directly.
func (r *Manager[C]) CapacityCooled(providerID, modelID string, now time.Time) bool {
	return r.lookupGateForSession(providerID).capacityCooled(modelID, now)
}

// capacityCooled reports whether routing should skip the pair. READ-ONLY (no
// lazy delete, no claim): lock-free "no cooldown entry on any model" fast
// path, otherwise one short gate.mu section. nil-safe.
//
// Half-open semantics: inside the TTL the gate is closed. Once now reaches the
// expiry it opens ONLY while no probe claim is fresh — the first reservation
// through claims the probe (tryClaimCapacityProbe, at commit), which closes
// the gate again for everyone else until the probe's outcome lands (accept
// deletes the entry; reject re-arms it) or the claim goes stale after
// capacityProbeOutcomeWindow (a lost probe must not wedge the pair).
func (g *gateState) capacityCooled(modelID string, now time.Time) bool {
	if !g.hasPairState(gateFlagCapacityCooldown) {
		return false
	}
	g = g.lockResolved()
	defer g.mu.Unlock()
	e, ok := g.capacityCooldowns[modelID]
	if !ok {
		return false
	}
	if now.Before(e.expiry) {
		return true
	}
	// Expired: closed to everyone but the single claimed probe while its
	// outcome is pending; open when unclaimed or the claim went stale.
	return !e.probeAt.IsZero() && now.Before(e.probeAt.Add(capacityProbeOutcomeWindow))
}

// rebuildCapacityCooldownLocked applies the post-accept strike history from a
// fresh breaker. The caller has removed every strike answered by the accept.
func (g *gateState) rebuildCapacityCooldownLocked(cfg capacityCooldownConfig, modelID string) {
	previous := g.capacityCooldowns[modelID]
	delete(g.capacityCooldowns, modelID)
	delete(g.capacityCooldownTrips, modelID)
	strikes := g.capacityRejectStrikes[modelID]
	if cfg.Threshold <= 0 || len(strikes) < cfg.Threshold {
		return
	}
	var expiry time.Time
	trips := 0
	for i, strike := range strikes {
		if strike.Before(expiry) || (trips == 0 && i+1 < cfg.Threshold) {
			continue
		}
		expiry = strike.Add(capacityCooldownBackoff(cfg, trips))
		trips++
	}
	entry := &capacityCooldownEntry{expiry: expiry}
	if previous != nil && !previous.probeAt.IsZero() && !previous.probeAt.Before(expiry) {
		entry.probeAt = previous.probeAt
	}
	g.capacityCooldowns[modelID] = entry
	g.capacityCooldownTrips[modelID] = trips
}
