package registry

import (
	"time"
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

// healthEjectionEnabled is the kill switch. Default ON;
// EIGENINFERENCE_HEALTH_EJECTION set to off/0/false/no disables both gating and
// recording. The value is read from the environment ONCE at process start
// (health_ejection_switch.go): a process's environment cannot change underneath
// it, so the former per-call os.Getenv + ToLower/TrimSpace — evaluated once per
// provider per routing scan — never actually toggled anything live; it only
// cost ~3% of the fleet-scale scan. Tests flip it through
// setHealthEjectionEnabledForTest.
func healthEjectionEnabled() bool {
	return healthEjectionSwitch.Load()
}

// stableProviderIdentityLocked derives a provider's stable identity (precedence:
// hardware serial → SE public key → account id), or "" when none is available
// (un-attestable → never ejected, fail-open).
//
// Serial and SE key are trusted ONLY from a VALID attestation result: both come
// from the attestation blob, which is attacker-supplied until its signature
// verifies, so an invalid result can carry another machine's serial — deriving
// an identity from it would bind a hostile session's fault state under
// "serial:<victim>" and deroute the legitimate machine when it reconnects.
// Valid-gating (not MDA-gating) is deliberate: VerificationResult carries no
// MDA/trust field — that state lives on Provider and is granted later by the
// bounded MDM/MDA scheduler. A Valid-but-uncrosschecked serial cannot accumulate
// served-fault state in production because routing requires hardware trust, and
// every grant still cross-checks the attested serial/device identity.
// The account fallback is safe on any result: AccountID is stamped from the
// authenticated provider token at registration, never from the attestation blob.
//
// Reads p.AttestationResult / p.AccountID DIRECTLY — it must NOT take p.mu. The
// routing gate (providerPassesRoutingGatesLockedEx) calls this with p.mu ALREADY
// HELD (snapshotProviderLocked* holds it; the gate reads p.Status/p.TrustLevel the
// same direct way), so re-locking via p.GetAttestationResult() self-deadlocks the
// gate. The only lock-free caller, GetProviderStableIdentity, takes p.mu itself
// before calling — so every path reads these fields under p.mu without re-entrancy.
func stableProviderIdentityLocked(p *Provider) string {
	if p == nil {
		return ""
	}
	if ar := p.AttestationResult; ar != nil && ar.Valid {
		if ar.SerialNumber != "" {
			return "serial:" + ar.SerialNumber
		}
		if ar.PublicKey != "" {
			return "sekey:" + ar.PublicKey
		}
	}
	if p.AccountID != "" {
		return "acct:" + p.AccountID
	}
	return ""
}

// GetProviderStableIdentity resolves a live session providerID to its stable
// identity, or "" if the provider is gone or un-attestable. For the consumer
// note* hooks to feed RecordProviderServeOutcome without holding registry locks:
// the session index under gatesMu stands in for r.providers, so this never
// queues behind a registry writer.
func (r *Registry) GetProviderStableIdentity(providerID string) string {
	if providerID == "" {
		return ""
	}
	r.gatesMu.RLock()
	p := r.sessions[providerID]
	cached, hasCached := r.disconnectedStableIDs[providerID]
	r.gatesMu.RUnlock()
	if p != nil {
		// This path does NOT hold p.mu (unlike the routing gate), so take it for the
		// read — guarding against a concurrent SetAttestationResult (live re-attestation
		// writes p.AttestationResult under p.mu). Not nested with gatesMu, so no deadlock.
		p.mu.Lock()
		defer p.mu.Unlock()
		return stableProviderIdentityLocked(p)
	}
	// Provider already removed from the session index — typically because
	// Disconnect ran before the pending-request ErrorCh flush, which carries the
	// 502 "provider disconnected" faults that characterize a reconnecting zombie.
	// Fall back to the identity captured at disconnect so those faults are still
	// recorded against the stable-identity breaker (otherwise the dominant zombie
	// signal is never counted).
	if hasCached && time.Since(cached.at) < disconnectedStableIDTTL {
		return cached.id
	}
	return ""
}

// mergeChronologicalTimestamps returns the oldest-to-newest union of two
// already-ordered histories. Identity migration is rare, so allocate only when
// both identities already hold state; the common move-to-empty case reuses the
// source slice. Equal timestamps remain distinct outcomes.
func mergeChronologicalTimestamps(dst, src []time.Time) []time.Time {
	if len(dst) == 0 {
		return src
	}
	if len(src) == 0 {
		return dst
	}

	merged := make([]time.Time, 0, len(dst)+len(src))
	i, j := 0, 0
	for i < len(dst) && j < len(src) {
		if !dst[i].After(src[j]) {
			merged = append(merged, dst[i])
			i++
		} else {
			merged = append(merged, src[j])
			j++
		}
	}
	merged = append(merged, dst[i:]...)
	merged = append(merged, src[j:]...)
	return merged
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
func (r *Registry) rememberDisconnectedStableIDLocked(sessionID, stableID string, disconnectedAt time.Time) {
	if r.disconnectedStableIDs == nil {
		r.disconnectedStableIDs = make(map[string]disconnectedStableID)
	}
	if len(r.disconnectedStableIDs) > 4096 {
		cutoff := time.Now().Add(-disconnectedStableIDTTL)
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
func (r *Registry) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string) (ejected, recovered bool) {
	if stableID == "" || !healthEjectionEnabled() {
		return false, false
	}
	hold := r.lockGate(r.gateForKey(stableID), "health_ejection")
	defer hold.unlock()
	g := hold.g
	return r.recordProviderServeOutcomeOnGateLocked(g, ok, statusCode, errStr)
}

func (r *Registry) RecordProviderSessionServeOutcome(sessionID string, ok bool, statusCode int, errStr string) (ejected, recovered bool) {
	if sessionID == "" || !healthEjectionEnabled() || r.faultKeyForSession(sessionID) == sessionID {
		return false, false
	}
	source := r.captureDisconnectSource(sessionID)
	hold := r.lockGate(r.gateForSession(sessionID), "health_ejection")
	defer hold.unlock()
	g := hold.g
	if g == nil || g.key == sessionID || (!ok && statusCode == disconnectFlushStatusCode && source.supersededBy(g)) {
		return false, false
	}
	return r.recordProviderServeOutcomeOnGateLocked(g, ok, statusCode, errStr)
}

func (r *Registry) recordProviderServeOutcomeOnGateLocked(g *gateState, ok bool, statusCode int, errStr string) (ejected, recovered bool) {
	now := time.Now()
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
		w.recordFault(now, statusCode == disconnectFlushStatusCode)

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
func (r *Registry) ejectionOpen(stableID string, now time.Time) bool {
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
func (r *Registry) ejectionOpenFor(g *gateState, sid string, nowNS int64) bool {
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
func (r *Registry) HealthEjectionOpen(stableID string) bool {
	return r.ejectionOpen(stableID, time.Now())
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
