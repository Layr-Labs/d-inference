package faultstate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Stable-identity health ejection.
//
// SEPARATE from the node-health breaker (breaker.go): this breaker
// keys on a STABLE identity (hardware serial → SE public key → account) that
// survives reconnect churn within a coordinator lifetime, and is NEVER deleted
// on Disconnect. A node whose stable identity collapses to a near-total
// served-fault rate — OR that capacity-rejects everything with zero successes
// (the 2026-07 black hole: 13,333 "token_budget"-shaped 503s at 100% error
// rate, invisible to every fault breaker because capacity sheds are neutral
// to them) — is ejected from routing, re-probed after an exponential cooldown
// (half-open), and auto-re-admitted on the first success.
//
// The session→identity fault-key binding (Manager.Bind in migration.go and
// Manager.FaultKeyForSession in index.go) that EVERY fault tracker keys by lives
// with the per-identity gate index, so ALL fault state re-attaches when a
// machine reconnects with a fresh session UUID instead of being wiped (the
// prod zombie exploit: median 18 sessions/machine/week reset every
// session-keyed breaker before it could trip). Registry derives the attested
// stable identity in fault_identity.go; this owner maintains ejection history.
//
// FAIL OPEN, like breaker.go: occasional capacity/client sheds never
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
// State lives on the identity's gate (state.go), filed under the stable
// id itself; only gate.mu is taken, never r.mu.
func (r *Manager[C]) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	hold := r.lockGate(r.gateForKey(stableID), "health_ejection")
	defer hold.unlock()
	g := hold.g
	return r.recordProviderServeOutcomeOnGateLocked(g, ok, statusCode, errStr, !ok && isDisconnectFlush(statusCode, causes))
}

func (r *Manager[C]) RecordProviderSessionServeOutcome(sessionID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	flush := !ok && isDisconnectFlush(statusCode, causes)
	var source disconnectSource[C]
	if flush {
		source = r.captureDisconnectSource(sessionID)
	}
	hold := r.lockGate(r.gateForSession(sessionID), "health_ejection")
	defer hold.unlock()
	g := hold.g
	if g == nil || g.key == sessionID || (flush && source.supersededBy(g)) {
		return false, false
	}
	return r.recordProviderServeOutcomeOnGateLocked(g, ok, statusCode, errStr, !ok && isDisconnectFlush(statusCode, causes))
}

func (r *Manager[C]) recordProviderServeOutcomeOnGateLocked(g *gateState, ok bool, statusCode int, errStr string, flush bool) (ejected, recovered bool) {
	now := r.now()
	defer g.updatedLocked(now)

	if ok {
		g.ejectionWindowLocked().record(true, now)
		g.ejectionCapacityStreak = capacityStreak{}
		if !g.ejectionUntil.IsZero() {
			g.ejectionUntil = time.Time{}
			g.ejectionTrips = 0
			g.ejectionLastTripCapacity = false
			return false, true // half-open probe succeeded → recover
		}
		return false, false
	}

	if providerOutcomeIsFault(statusCode, errStr) {
		w := g.ejectionWindowLocked()
		w.recordFault(now, flush)

		if now.Before(g.ejectionUntil) {
			return false, false // already ejected; in-flight faults don't re-arm until cooldown
		}
		trips := g.ejectionTrips
		halfOpen := trips > 0
		total, fails := w.windowStats(now, healthEjectionWindow)
		rateTrip := total >= healthEjectionMinSample &&
			float64(total-fails) < healthEjectionMinSuccessRate*float64(total)
		if !halfOpen && w.consecFail < healthEjectionConsecTrip && !rateTrip {
			return false, false
		}
		g.ejectionUntil = now.Add(healthEjectionBackoff(trips))
		g.ejectionTrips = trips + 1
		g.ejectionLastTripCapacity = false
		return true, false
	}

	if isNodeCapacityRejectStrike(statusCode, errStr) {
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
// (ejectionOpenFor) and never comes here.
func (r *Manager[C]) ejectionOpen(stableID string, now time.Time) bool {
	if stableID == "" {
		return false
	}
	return r.lookupGateForKey(stableID).ejectedAt(now.UnixNano())
}

// ejectionOpenFor is the scan's ejection check for provider p whose stable
// identity is sid: when the session's cached gate IS the identity's gate (the
// steady state — bindStableFaultKey filed the session under sid) the answer is
// one atomic load; only a session whose bind has not caught up with its
// identity pays a gatesMu.RLock lookup.
func (r *Manager[C]) ejectionOpenFor(g *gateState, sid string, nowNS int64) bool {
	if sid == "" {
		return false
	}
	if g != nil && g.key == sid {
		return g.ejectedAt(nowNS)
	}
	return r.lookupGateForKey(sid).ejectedAt(nowNS)
}

// HealthEjectionOpen reports whether a stable identity is currently ejected.
// Exposed for tests/observability.
func (r *Manager[C]) HealthEjectionOpen(stableID string) bool {
	return r.ejectionOpen(stableID, r.now())
}

// ejectionWindowLocked returns the gate's ejection ring, creating it on first
// use. Caller holds g.mu.
func (g *gateState) ejectionWindowLocked() *providerHealthWindow {
	if g.ejection == nil {
		g.ejection = &providerHealthWindow{}
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
