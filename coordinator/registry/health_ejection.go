package registry

import (
	"os"
	"strings"
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
// This file also owns the session→identity fault-key binding
// (bindStableFaultKey / faultKeyLocked) that the OTHER fault trackers
// (error_cooldown.go, provider_breaker.go, dispatchLoadCooldowns) key their
// maps by, so ALL fault state re-attaches when a machine reconnects with a
// fresh session UUID instead of being wiped (the prod zombie exploit: median
// 18 sessions/machine/week reset every session-keyed breaker before it could
// trip).
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
// Serial and SE key are trusted ONLY from a VALID attestation result: both come
// from the attestation blob, which is attacker-supplied until its signature
// verifies, so an invalid result can carry another machine's serial — deriving
// an identity from it would bind a hostile session's fault state under
// "serial:<victim>" and deroute the legitimate machine when it reconnects.
// Valid-gating (not MDA-gating) is deliberate: VerificationResult carries no
// MDA/trust field — that state lives on the Provider and is granted later by
// the MDM/MDA loops, so keying on it would flip a session's identity
// mid-connection with no rebind — and a Valid-but-uncrosschecked serial cannot
// accumulate served-fault state in production because routing requires
// hardware trust, which MDM/MDA grant only after matching the attested serial
// (SetMDAProofIfHardware*, mdmVerificationLoop). The account fallback is safe
// on ANY result: AccountID is stamped from the authenticated provider token at
// registration, never from the attestation blob.
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

// bindStableFaultKey binds a live session id to its stable identity so every
// fault-tracking map (inference-error cooldowns, node-health breaker,
// dispatch-load cooldowns) keys by identity and survives reconnects. Called by
// SetAttestationResult on every (re-)attestation — i.e. BEFORE the session is
// routable for public traffic — which is what re-attaches a reconnecting
// machine's accumulated fault state to its fresh session id. An empty stableID
// (attestation cleared / never valid) unbinds, falling back to session keying.
func (r *Registry) bindStableFaultKey(sessionID, stableID string) {
	if sessionID == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if stableID == "" {
		delete(r.faultKeyBySession, sessionID)
		return
	}
	// Only bind LIVE sessions: a re-attestation racing Disconnect must not
	// re-insert an entry Disconnect already removed (it would leak forever —
	// nothing cleans that session id again). The disconnectedStableIDs cache
	// covers post-disconnect resolution.
	if _, live := r.providers[sessionID]; !live {
		return
	}
	// Migrate accumulated fault state when the key changes: from the session id
	// on the FIRST bind (strikes recorded pre-attestation live under the
	// faultKeyLocked session fallback), or from the previous identity on a
	// rebind (e.g. sekey: → serial: after MDA enrichment). Without this, a
	// machine near quarantine sheds its history at the exact moment its
	// identity improves. No-op on the common re-attestation with an unchanged
	// identity.
	old := r.faultKeyBySession[sessionID]
	if old == "" {
		old = sessionID
	}
	if old != stableID {
		r.migrateFaultStateLocked(old, stableID)
	}
	r.faultKeyBySession[sessionID] = stableID
}

// migrateFaultStateLocked re-keys every fault-tracking map entry from oldKey to
// newKey so accumulated history follows an identity rebind. Merge policy where
// both keys hold state: expiries and streak recency take the max, trip counts
// take the max, timestamp histories merge chronologically (their bounded-map
// sweeps use the tail as the newest entry), and health windows are merged in
// timestamp order bounded by the ring size (providerHealthWindow.merge) so an
// in-progress consecutive-fault streak survives the rebind. Caller holds r.mu.
func (r *Registry) migrateFaultStateLocked(oldKey, newKey string) {
	if oldKey == "" || newKey == "" || oldKey == newKey {
		return
	}

	// Dispatch-load cooldowns: composite "key:modelID" string keys.
	prefix := oldKey + ":"
	for k, expiry := range r.dispatchLoadCooldowns {
		if strings.HasPrefix(k, prefix) {
			nk := newKey + ":" + k[len(prefix):]
			if cur, ok := r.dispatchLoadCooldowns[nk]; !ok || expiry.After(cur) {
				r.dispatchLoadCooldowns[nk] = expiry
			}
			delete(r.dispatchLoadCooldowns, k)
		}
	}

	// Inference-error strikes/cooldowns: struct keys per (provider, model, shape).
	for k, strikes := range r.inferenceErrorStrikes {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			r.inferenceErrorStrikes[nk] = mergeChronologicalTimestamps(r.inferenceErrorStrikes[nk], strikes)
			delete(r.inferenceErrorStrikes, k)
		}
	}
	for k, expiry := range r.inferenceErrorCooldowns {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			if cur, ok := r.inferenceErrorCooldowns[nk]; !ok || expiry.After(cur) {
				r.inferenceErrorCooldowns[nk] = expiry
			}
			delete(r.inferenceErrorCooldowns, k)
		}
	}

	// Node-health breaker.
	if w, ok := r.providerOutcomes[oldKey]; ok {
		if dst, exists := r.providerOutcomes[newKey]; exists {
			dst.merge(w)
		} else {
			r.providerOutcomes[newKey] = w
		}
		delete(r.providerOutcomes, oldKey)
	}
	if expiry, ok := r.providerBreakerOpenUntil[oldKey]; ok {
		if cur, exists := r.providerBreakerOpenUntil[newKey]; !exists || expiry.After(cur) {
			r.providerBreakerOpenUntil[newKey] = expiry
		}
		delete(r.providerBreakerOpenUntil, oldKey)
	}
	if trips, ok := r.providerBreakerTrips[oldKey]; ok {
		if cur, exists := r.providerBreakerTrips[newKey]; !exists || trips > cur {
			r.providerBreakerTrips[newKey] = trips
		}
		delete(r.providerBreakerTrips, oldKey)
	}

	// Capacity-reject cooldown (pair-scoped struct keys).
	for k, strikes := range r.capacityRejectStrikes {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			r.capacityRejectStrikes[nk] = mergeChronologicalTimestamps(r.capacityRejectStrikes[nk], strikes)
			delete(r.capacityRejectStrikes, k)
		}
	}
	for k, entry := range r.capacityCooldowns {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			if cur, ok := r.capacityCooldowns[nk]; !ok || entry.expiry.After(cur.expiry) {
				r.capacityCooldowns[nk] = entry
			}
			delete(r.capacityCooldowns, k)
		}
	}
	for k, trips := range r.capacityCooldownTrips {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			if cur, ok := r.capacityCooldownTrips[nk]; !ok || trips > cur {
				r.capacityCooldownTrips[nk] = trips
			}
			delete(r.capacityCooldownTrips, k)
		}
	}

	// Gray-box budget clamp: the entry with the LATER clamp time wins whole
	// (its clampedAt anchors both the TTL and the release-freshness check, and
	// its acceptedSince belongs to that clamp window).
	for k, entry := range r.budgetClamps {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			if cur, ok := r.budgetClamps[nk]; !ok || entry.clampedAt.After(cur.clampedAt) {
				r.budgetClamps[nk] = entry
			}
			delete(r.budgetClamps, k)
		}
	}

	// Capacity-503 rate windows: union the outcome slices chronologically. The
	// large-map sweep uses the tail as the newest timestamp, so appending an older
	// source history after a fresh destination would otherwise delete live state.
	for k, outcomes := range r.capacityRateRejects {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			r.capacityRateRejects[nk] = mergeChronologicalTimestamps(r.capacityRateRejects[nk], outcomes)
			delete(r.capacityRateRejects, k)
		}
	}
	for k, outcomes := range r.capacityRateAccepts {
		if k.ProviderID == oldKey {
			nk := k
			nk.ProviderID = newKey
			r.capacityRateAccepts[nk] = mergeChronologicalTimestamps(r.capacityRateAccepts[nk], outcomes)
			delete(r.capacityRateAccepts, k)
		}
	}

	// Stable-identity health ejection.
	if w, ok := r.healthEjectionWindows[oldKey]; ok {
		if dst, exists := r.healthEjectionWindows[newKey]; exists {
			dst.merge(w)
		} else {
			r.healthEjectionWindows[newKey] = w
		}
		delete(r.healthEjectionWindows, oldKey)
	}
	if until, ok := r.healthEjectionUntil[oldKey]; ok {
		if cur, exists := r.healthEjectionUntil[newKey]; !exists || until.After(cur) {
			r.healthEjectionUntil[newKey] = until
		}
		delete(r.healthEjectionUntil, oldKey)
	}
	if trips, ok := r.healthEjectionTrips[oldKey]; ok {
		if cur, exists := r.healthEjectionTrips[newKey]; !exists || trips > cur {
			r.healthEjectionTrips[newKey] = trips
		}
		delete(r.healthEjectionTrips, oldKey)
	}
	if streak, ok := r.healthEjectionCapacityStreaks[oldKey]; ok {
		if cur, exists := r.healthEjectionCapacityStreaks[newKey]; !exists || streak.n > cur.n {
			r.healthEjectionCapacityStreaks[newKey] = streak
		}
		delete(r.healthEjectionCapacityStreaks, oldKey)
	}
	if lastCap, ok := r.healthEjectionLastTripCapacity[oldKey]; ok {
		if _, exists := r.healthEjectionLastTripCapacity[newKey]; !exists {
			r.healthEjectionLastTripCapacity[newKey] = lastCap
		}
		delete(r.healthEjectionLastTripCapacity, oldKey)
	}
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

// faultKeyLocked resolves a session provider id to the key its fault state
// lives under: the bound stable identity (serial/SE-key/account), the identity
// cached at Disconnect for the trailing ErrorCh flush, or — when no identity
// was ever available — the session id itself. READ-ONLY (no map writes), so it
// is safe under r.mu held in either mode; the routing gates call it under
// r.mu.RLock.
func (r *Registry) faultKeyLocked(sessionID string) string {
	if k, ok := r.faultKeyBySession[sessionID]; ok && k != "" {
		return k
	}
	if c, ok := r.disconnectedStableIDs[sessionID]; ok && c.id != "" && time.Since(c.at) < disconnectedStableIDTTL {
		return c.id
	}
	return sessionID
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
		delete(r.healthEjectionCapacityStreaks, stableID)
		if _, had := r.healthEjectionUntil[stableID]; had {
			delete(r.healthEjectionUntil, stableID)
			delete(r.healthEjectionTrips, stableID)
			delete(r.healthEjectionLastTripCapacity, stableID)
			return false, true // half-open probe succeeded → recover
		}
		return false, false
	}

	if providerOutcomeIsFault(statusCode, errStr) {
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
		r.healthEjectionLastTripCapacity[stableID] = false
		return true, false
	}

	if isNodeCapacityRejectStrike(statusCode, errStr) {
		s := r.healthEjectionCapacityStreaks[stableID]
		if s.n > 0 && now.Sub(s.last) > healthEjectionWindow {
			s.n = 0 // stale streak: never combine old strikes with a fresh blip
		}
		s.n++
		s.last = now
		r.healthEjectionCapacityStreaks[stableID] = s

		if until, had := r.healthEjectionUntil[stableID]; had && now.Before(until) {
			return false, false // already ejected; stragglers don't re-arm until cooldown
		}
		trips := r.healthEjectionTrips[stableID]
		// Half-open instant re-arm applies ONLY when the previous trip was
		// itself capacity-shaped (the black-hole probe failing again): a single
		// capacity shed is legitimate for a healthy-but-full box and must not
		// re-arm a FAULT ejection whose cooldown just expired — that identity
		// needs the full zero-success streak like a fresh one.
		capacityHalfOpen := trips > 0 && r.healthEjectionLastTripCapacity[stableID]
		if !capacityHalfOpen && s.n < healthEjectionCapacityConsecTrip {
			return false, false
		}
		r.healthEjectionUntil[stableID] = now.Add(healthEjectionBackoff(trips))
		r.healthEjectionTrips[stableID] = trips + 1
		r.healthEjectionLastTripCapacity[stableID] = true
		return true, false
	}

	return false, false
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
// by design, so only entries idle for longer than the window (no windowed
// outcomes, no fresh capacity streak, not currently ejected) are reaped, once
// the maps grow large.
func (r *Registry) healthEjectionSweepLocked(now time.Time) {
	if len(r.healthEjectionWindows) > 2048 {
		for id, w := range r.healthEjectionWindows {
			if until, had := r.healthEjectionUntil[id]; had && now.Before(until) {
				continue
			}
			if s, ok := r.healthEjectionCapacityStreaks[id]; ok && now.Sub(s.last) <= healthEjectionWindow {
				continue
			}
			if total, _ := w.windowStats(now, healthEjectionWindow); total == 0 {
				delete(r.healthEjectionWindows, id)
				delete(r.healthEjectionUntil, id)
				delete(r.healthEjectionTrips, id)
				delete(r.healthEjectionCapacityStreaks, id)
				delete(r.healthEjectionLastTripCapacity, id)
			}
		}
	}
	// Capacity-only identities (pure black holes) never touch the fault ring,
	// so their streaks need their own staleness sweep.
	if len(r.healthEjectionCapacityStreaks) > 2048 {
		for id, s := range r.healthEjectionCapacityStreaks {
			if until, had := r.healthEjectionUntil[id]; had && now.Before(until) {
				continue
			}
			if now.Sub(s.last) > healthEjectionWindow {
				delete(r.healthEjectionCapacityStreaks, id)
			}
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
