package registry

import (
	"os"
	"strings"
	"time"
)

// Stable-identity health ejection.
//
// SEPARATE from the per-session node-health breaker (provider_breaker.go). That
// breaker is keyed by the per-connection session UUID (api/provider.go mints a
// fresh uuid.New() per WebSocket) and ALL its state is deleted on Disconnect.
// The "zombie" providers in production fail ~every request AND disconnect
// constantly (jetsam/OOM, ~7,880 disconnects/48h), so their session-keyed fault
// state is wiped before it can accumulate to the trip threshold — they stay
// routable with ~0 successes indefinitely.
//
// This breaker keys on a STABLE identity (hardware serial → SE public key →
// account) that survives reconnect churn within a coordinator lifetime, and is
// NEVER deleted on Disconnect. A node whose stable identity collapses to a near-
// total served-fault rate is ejected from routing, re-probed after an exponential
// cooldown (half-open), and auto-re-admitted on the first success.
//
// FAIL OPEN, like provider_breaker.go: capacity/client sheds never count (reuses
// providerOutcomeIsFault), an un-attestable provider (no stable identity) is never
// ejected, and the routing gate's selectBestCandidateLockedFull fail-open rescan
// (ignoreProviderBreaker) bypasses this gate too so a fleet-wide fault can't zero
// routing. State survives reconnect within ONE coordinator lifetime, NOT across a
// coordinator restart (same limitation as the session breaker; the prod store is
// in-memory).
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
	// healthEjectionBaseCooldown / MaxCooldown: exponential quarantine backoff.
	healthEjectionBaseCooldown = 60 * time.Second
	healthEjectionMaxCooldown  = 10 * time.Minute
)

// healthEjectionEnabled is the LIVE kill switch (read at evaluation time so it
// toggles without a coordinator restart). Default ON; EIGENINFERENCE_HEALTH_EJECTION
// set to off/0/false/no disables both gating and recording.
func healthEjectionEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("EIGENINFERENCE_HEALTH_EJECTION"))) {
	case "off", "0", "false", "no":
		return false
	default:
		return true
	}
}

// stableProviderIdentityLocked derives a provider's stable identity (precedence:
// hardware serial → SE public key → account id), or "" when none is available
// (un-attestable → never ejected, fail-open).
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
	if ar := p.AttestationResult; ar != nil {
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
// note* hooks to feed RecordProviderServeOutcome without holding registry locks.
func (r *Registry) GetProviderStableIdentity(providerID string) string {
	if providerID == "" {
		return ""
	}
	r.mu.RLock()
	p := r.providers[providerID]
	cached, hasCached := r.disconnectedStableIDs[providerID]
	r.mu.RUnlock()
	if p != nil {
		// This path does NOT hold p.mu (unlike the routing gate), so take it for the
		// read — guarding against a concurrent SetAttestationResult (live re-attestation
		// writes p.AttestationResult under p.mu). Not nested with r.mu, so no deadlock.
		p.mu.Lock()
		defer p.mu.Unlock()
		return stableProviderIdentityLocked(p)
	}
	// Provider already removed from r.providers — typically because Disconnect ran
	// before the pending-request ErrorCh flush, which carries the 502 "provider
	// disconnected" faults that characterize a reconnecting zombie. Fall back to the
	// identity captured at disconnect so those faults are still recorded against the
	// stable-identity breaker (otherwise the dominant zombie signal is never counted).
	if hasCached && time.Since(cached.at) < disconnectedStableIDTTL {
		return cached.id
	}
	return ""
}

// disconnectedStableID caches a provider's stable identity at Disconnect time so
// the trailing pending-request ErrorCh flush can still resolve it.
type disconnectedStableID struct {
	id string
	at time.Time
}

// disconnectedStableIDTTL bounds how long a disconnected provider's cached stable
// identity stays resolvable — long enough for the synchronous pending-request flush
// and any immediately-trailing terminal, short enough to stay tiny.
const disconnectedStableIDTTL = 2 * time.Minute

// rememberDisconnectedStableIDLocked caches a provider's stable identity keyed by
// its about-to-be-removed session id. Caller holds r.mu.
func (r *Registry) rememberDisconnectedStableIDLocked(sessionID, stableID string) {
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
	r.disconnectedStableIDs[sessionID] = disconnectedStableID{id: stableID, at: time.Now()}
}

// RecordProviderServeOutcome feeds one terminal outcome into the stable-identity
// ejection breaker. ok = the request ultimately succeeded; statusCode/errStr
// describe a failure. Returns ejected=true only on the transition into quarantine
// and recovered=true only on the transition out (so callers emit metrics once).
// Capacity/client sheds (providerOutcomeIsFault==false) are neutral.
func (r *Registry) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string) (ejected, recovered bool) {
	if stableID == "" || !healthEjectionEnabled() {
		return false, false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()
	r.healthEjectionSweepLocked(now)

	if ok {
		r.healthEjectionWindowLocked(stableID).record(true, now)
		if _, had := r.healthEjectionUntil[stableID]; had {
			delete(r.healthEjectionUntil, stableID)
			delete(r.healthEjectionTrips, stableID)
			return false, true // half-open probe succeeded → recover
		}
		return false, false
	}

	// Served faults only — capacity sheds (token budget / KV / queue / 4xx) are a
	// healthy-but-busy or client-shape signal and must never eject a node.
	if !providerOutcomeIsFault(statusCode, errStr) {
		return false, false
	}
	w := r.healthEjectionWindowLocked(stableID)
	w.record(false, now)

	if until, had := r.healthEjectionUntil[stableID]; had && now.Before(until) {
		return false, false // already ejected; in-flight faults don't re-arm until cooldown
	}
	trips := r.healthEjectionTrips[stableID]
	halfOpen := trips > 0
	total, fails := w.windowStats(now, healthEjectionWindow)
	rateTrip := total >= healthEjectionMinSample &&
		float64(total-fails) < healthEjectionMinSuccessRate*float64(total)
	if !halfOpen && w.consecFail < healthEjectionConsecTrip && !rateTrip {
		return false, false
	}
	r.healthEjectionUntil[stableID] = now.Add(healthEjectionBackoff(trips))
	r.healthEjectionTrips[stableID] = trips + 1
	return true, false
}

// healthEjectionOpenLocked reports whether routing should skip this stable
// identity. READ-ONLY (no lazy delete); caller holds r.mu in either mode.
func (r *Registry) healthEjectionOpenLocked(stableID string, now time.Time) bool {
	if stableID == "" {
		return false
	}
	until, ok := r.healthEjectionUntil[stableID]
	return ok && now.Before(until)
}

// HealthEjectionOpen reports whether a stable identity is currently ejected.
// Exposed for tests/observability.
func (r *Registry) HealthEjectionOpen(stableID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.healthEjectionOpenLocked(stableID, time.Now())
}

func (r *Registry) healthEjectionWindowLocked(stableID string) *providerHealthWindow {
	w := r.healthEjectionWindows[stableID]
	if w == nil {
		w = &providerHealthWindow{}
		r.healthEjectionWindows[stableID] = w
	}
	return w
}

// healthEjectionSweepLocked bounds the maps. Stable ids persist across reconnects
// by design, so only entries idle for longer than the max cooldown (no windowed
// outcomes, not currently ejected) are reaped, once the map grows large.
func (r *Registry) healthEjectionSweepLocked(now time.Time) {
	if len(r.healthEjectionWindows) <= 2048 {
		return
	}
	for id, w := range r.healthEjectionWindows {
		if until, had := r.healthEjectionUntil[id]; had && now.Before(until) {
			continue
		}
		if total, _ := w.windowStats(now, healthEjectionWindow); total == 0 {
			delete(r.healthEjectionWindows, id)
			delete(r.healthEjectionUntil, id)
			delete(r.healthEjectionTrips, id)
		}
	}
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
