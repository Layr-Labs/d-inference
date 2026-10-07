package identitygate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Stable-identity health ejection + the stable fault-key infrastructure.
//
// SEPARATE from the node-health breaker (provider_breaker.go): this breaker
// keys on a STABLE identity (hardware serial → SE public key → account) that
// survives reconnect churn within a coordinator lifetime, and is NEVER deleted
// on Disconnect. A node whose stable identity collapses to a near-total
// served-fault rate — OR that capacity-rejects everything with zero successes
// (the 2026-07 black hole: 13,333 "token_budget"-shaped 503s at 100% error
// rate, invisible to every fault breaker because capacity sheds are neutral
// to them) — is ejected from routing, re-probed after an exponential cooldown
// (half-open), and auto-re-admitted on the first success.
//
// The session→identity fault-key binding (bindStableFaultKey /
// faultKeyForSession, gate_state.go) that EVERY fault tracker keys by lives
// with the per-identity gate index, so ALL fault state re-attaches when a
// machine reconnects with a fresh session UUID instead of being wiped (the
// prod zombie exploit: median 18 sessions/machine/week reset every
// session-keyed breaker before it could trip). This file derives the stable
// identity and owns the ejection breaker itself.
//
// FAIL OPEN, like provider_breaker.go: occasional capacity/client sheds never
// count (only an unbroken zero-success capacity streak does), an un-attestable
// provider (no stable identity) is never ejected, and the routing gate's
// selectBestCandidateLockedFull fail-open rescan (ignoreProviderBreaker)
// bypasses this gate too so a fleet-wide fault can't zero routing. State
// survives reconnect within ONE coordinator lifetime, NOT across a coordinator
// restart (the live registry is in-process).
const (
	// healthEjectionConsecTrip: consecutive served faults (no success between)
	// that eject. The zombie signature (0 successes) trips here fast.
	healthEjectionConsecTrip = 8
	// healthEjectionMinSample: minimum windowed outcomes before the rate condition
	// can trip — avoids ejecting on a tiny unlucky sample. Must be <= the ring size
	// (providerHealthRingSize) so a full ring can satisfy it.
	healthEjectionMinSample = 15
	// healthEjectionMinSuccessRate: eject when the success fraction over the window
	// falls below this (i.e. ~90%+ served-fault) AND the sample is large enough.
	healthEjectionMinSuccessRate = 0.10
	// healthEjectionWindow: sliding window for the rate condition. Longer than the
	// session breaker's 120s so it accumulates across reconnect churn.
	healthEjectionWindow = 10 * time.Minute
	// healthEjectionCapacityConsecTrip: consecutive CAPACITY-shaped 5xx
	// rejections (zero successes in between, any model) that eject the node.
	// The 2026-07 black hole: 13,333 "token_budget"-shaped 503s at a 100%
	// error rate that no fault breaker could see, because capacity sheds are
	// (correctly) neutral to all of them. The discriminator that keeps a
	// busy-but-serving box safe is the ZERO-interleaved-success requirement:
	// any served request resets the streak, and the per-pair capacity-reject
	// cooldown (capacity_cooldown.go, threshold 5) throttles dispatch to a
	// rejecting pair long before this node-level backstop is reached. Higher
	// than healthEjectionConsecTrip because a shedding box is usually healthy;
	// a box that sheds EVERYTHING and serves NOTHING is a black hole.
	healthEjectionCapacityConsecTrip = 10
	// healthEjectionBaseCooldown / MaxCooldown: exponential quarantine backoff.
	healthEjectionBaseCooldown = 60 * time.Second
	healthEjectionMaxCooldown  = 10 * time.Minute
)

// capacityStreak tracks consecutive capacity-shaped rejections for one stable
// identity. last bounds staleness: a streak whose most recent strike is older
// than healthEjectionWindow restarts instead of combining with fresh strikes.
type capacityStreak struct {
	n    int
	last time.Time
}

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
func (r *Directory) rememberDisconnectedStableIDLocked(sessionID, stableID string, disconnectedAt time.Time) {
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

// RecordProviderServeOutcome feeds one terminal outcome into the stable-identity
// ejection breaker. ok = the request ultimately succeeded; statusCode/errStr
// describe a failure. Returns ejected=true only on the transition into quarantine
// and recovered=true only on the transition out (so callers emit metrics once).
//
// Three failure classes:
//   - genuine faults (providerOutcomeIsFault): the fault ring + consecutive /
//     rate trip conditions;
//   - capacity-shaped 5xx (isNodeCapacityRejectStrike): a separate consecutive
//     streak that ejects only at healthEjectionCapacityConsecTrip with ZERO
//     interleaved successes — the black-hole signature the fault path is blind
//     to, while a busy-but-serving box (whose completions reset the streak)
//     can never trip;
//   - everything else (client 4xx, request-shape context overflows,
//     unattributed codes): neutral.
//
// State lives on the identity's gate (gate_state.go), filed under the stable
// id itself; only gate.mu is taken, never r.mu.
func (r *Directory) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	if stableID == "" || !r.healthEjectionEnabled() {
		return false, false
	}
	hold := r.lockGate(r.gateForKey(stableID), "health_ejection")
	defer hold.unlock()
	g := hold.g
	return r.recordProviderServeOutcomeOnGateLocked(g, ok, statusCode, errStr, !ok && isDisconnectFlush(statusCode, causes))
}

func (r *Directory) RecordProviderSessionServeOutcome(sessionID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	if sessionID == "" || !r.healthEjectionEnabled() || r.faultKeyForSession(sessionID) == sessionID {
		return false, false
	}
	flush := !ok && isDisconnectFlush(statusCode, causes)
	var source DisconnectSource
	if flush {
		source = r.CaptureDisconnectSource(sessionID)
	}
	hold := r.lockGate(r.gateForSession(sessionID), "health_ejection")
	defer hold.unlock()
	g := hold.g
	if g == nil || g.key == sessionID || (flush && source.supersededBy(g)) {
		return false, false
	}
	return r.recordProviderServeOutcomeOnGateLocked(g, ok, statusCode, errStr, !ok && isDisconnectFlush(statusCode, causes))
}

func (r *Directory) recordProviderServeOutcomeOnGateLocked(g *State, ok bool, statusCode int, errStr string, flush bool) (ejected, recovered bool) {
	now := r.now()
	defer g.updatedLocked(now)

	if ok {
		g.ejectionWindowLocked().Record(true, now)
		g.ejectionCapacityStreak = capacityStreak{}
		if !g.ejectionUntil.IsZero() {
			g.ejectionUntil = time.Time{}
			g.ejectionTrips = 0
			g.ejectionLastTripCapacity = false
			return false, true // half-open probe succeeded → recover
		}
		return false, false
	}

	if ProviderOutcomeIsFault(statusCode, errStr) {
		w := g.ejectionWindowLocked()
		w.RecordFault(now, flush)
		assessment := g.ejectionAssessmentLocked(now)

		if now.Before(assessment.RetryAfter) {
			return false, false // already ejected; in-flight faults don't re-arm until cooldown
		}
		trips := assessment.Trips
		if !assessment.NeedsProbe() && assessment.ConsecutiveFaults < healthEjectionConsecTrip && !assessment.ejectionRateTrips() {
			return false, false
		}
		g.ejectionUntil = now.Add(healthEjectionBackoff(trips))
		g.ejectionTrips = trips + 1
		g.ejectionLastTripCapacity = false
		return true, false
	}

	if IsNodeCapacityRejectStrike(statusCode, errStr) {
		s := g.ejectionCapacityStreak
		if s.n > 0 && now.Sub(s.last) > healthEjectionWindow {
			s.n = 0 // stale streak: never combine old strikes with a fresh blip
		}
		s.n++
		s.last = now
		g.ejectionCapacityStreak = s

		if now.Before(g.ejectionUntil) {
			return false, false // already ejected; stragglers don't re-arm until cooldown
		}
		trips := g.ejectionTrips
		// Half-open instant re-arm applies ONLY when the previous trip was
		// itself capacity-shaped (the black-hole probe failing again): a single
		// capacity shed is legitimate for a healthy-but-full box and must not
		// re-arm a FAULT ejection whose cooldown just expired — that identity
		// needs the full zero-success streak like a fresh one.
		capacityHalfOpen := trips > 0 && g.ejectionLastTripCapacity
		if !capacityHalfOpen && s.n < healthEjectionCapacityConsecTrip {
			return false, false
		}
		g.ejectionUntil = now.Add(healthEjectionBackoff(trips))
		g.ejectionTrips = trips + 1
		g.ejectionLastTripCapacity = true
		return true, false
	}

	return false, false
}

// ejectionOpen reports whether routing should skip this stable identity.
// Resolves the identity's gate; the scan reads the cached p.gate atomically
// through its View and never comes here.
func (r *Directory) ejectionOpen(stableID string, now time.Time) bool {
	if stableID == "" {
		return false
	}
	return r.lookupGateForKey(stableID).ejectedAt(now.UnixNano())
}

// HealthEjectionOpen reports whether a stable identity is currently ejected.
// Exposed for tests/observability.
func (r *Directory) HealthEjectionOpen(stableID string) bool {
	return r.ejectionOpen(stableID, time.Now())
}

// ejectionWindowLocked returns the gate's ejection ring, creating it on first
// use. Caller holds g.mu.
func (g *State) ejectionWindowLocked() *HealthHistory {
	if g.ejection == nil {
		g.ejection = &HealthHistory{}
	}
	return g.ejection
}

// healthEjectionBackoff: base * 2^trips capped at the max (mirrors providerBreakerBackoff).
func healthEjectionBackoff(trips int) time.Duration {
	cooldown := healthEjectionBaseCooldown
	for i := 0; i < trips && cooldown < healthEjectionMaxCooldown; i++ {
		cooldown *= 2
	}
	if cooldown > healthEjectionMaxCooldown {
		cooldown = healthEjectionMaxCooldown
	}
	return cooldown
}
