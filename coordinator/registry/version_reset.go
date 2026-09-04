package registry

import "time"

// Version-changed reconnect reset (R1, upgrade waves).
//
// The Swift provider's auto-update restart exits the process without a
// WebSocket close frame (ProcessLifecycle.restartAfterUpdate → launchctl
// kickstart -k → exit), so the coordinator books it as an ABRUPT drop and the
// flush of every in-flight request lands as a 502 strike on the provider's
// STABLE identity — deliberately, because that flush is the reconnecting-
// zombie signal. A fleet upgrade therefore returned every box quarantined
// (2026-08-31: inference-error cooldowns for 5 min, node breakers, ejections).
//
// The distinguishing fact is only known on RECONNECT: the same identity comes
// back running a DIFFERENT binary version. When that happens, exactly the
// disconnect-flush strikes — the 502s — are removed from the identity's
// windows and each quarantine is re-evaluated against what remains, so:
//   - a healthy box that died mid-upgrade with work in flight comes back
//     clean;
//   - genuine 500/504 faults recorded BEFORE the restart are kept, and a
//     breaker whose trip still holds without the 502s stays open;
//   - a zombie that churns on the SAME version keeps every strike — the
//     reset never fires without a version change.
//
// The 502 status is the flush marker throughout the registry (see
// RecordInferenceError: "502 — disconnect flush"). Providers do not originate
// 502s except the rare encryption_failure terminal, which is acceptable
// collateral: it says nothing about the NEW binary either.
//
// Two seams observe the version because registration binds the identity
// BEFORE the api layer stores RegisterMessage.Version: bindStableFaultKey
// (re-attestation on an already-versioned session) and Provider.SetVersion
// (registration on an already-bound session). Both funnel into
// noteIdentityVersionLocked; only a CHANGE from the last version seen for the
// identity triggers the reset. State lives in identityVersions and
// inferenceErrorFlushStrikes (Registry, guarded by r.mu; lazily created so
// bare test registries work). The flush tags live exactly as long as the
// strikes they mark: RecordInferenceError slides them out of the breaker
// window with the strikes and RecordInferenceSuccess drops them with the
// history, so an identity that never changes version cannot accumulate them.
//
// The flush strikes are recorded by the request goroutines that drain the
// flushed ErrorCh, not by Disconnect itself, so they can land AFTER the reset:
// registration evicts a same-serial predecessor (DisconnectDuplicatesBySerial)
// and stores the new version on the same goroutine, and a slow consumer can
// trail a normal reconnect. A reset that ran first cleared nothing, consumed
// the interval, and the late strikes would then quarantine the NEW binary for
// the old one's death. IsSupersededDisconnectFlush closes that order: a 502
// attributed to a session that was dropped at or before its identity's last
// reset (disconnectedStableIDs dates every drop) is discarded under each
// tracker mutation lock, with an API-side early return as an optimization — exactly the
// strikes the reset would have removed, and none from a session that died
// after it (same-version churn and a throttled version change keep striking).

// disconnectFlushStatusCode is the status the pending-request flush injects
// (registry.disconnectWithCause) and the marker the fault windows tag.
const disconnectFlushStatusCode = 502

// identityVersionResetMinInterval bounds how often one stable identity can
// have its flush strikes cleared by a version change. RegisterMessage.Version
// is provider-asserted and observed before release evidence, so a modified
// binary alternating two version strings could otherwise launder every
// reconnect's flush strikes; a genuine upgrade (or rollback) changes version
// once per rollout, and the strikes it would clear expire within the 5-minute
// cooldown anyway, so one reset per interval loses nothing legitimate.
const identityVersionResetMinInterval = 10 * time.Minute

// SetVersion stores the provider's reported binary version and, when the
// session is already bound to a stable identity, runs the version-changed
// reset for that identity. Registration calls it after attestation has bound
// the session, which is why the check lives here as well as in
// bindStableFaultKey.
func (p *Provider) SetVersion(version string) {
	p.mu.Lock()
	p.Version = version
	id, r := p.ID, p.registry
	p.mu.Unlock()
	if r == nil || version == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if stableID := r.faultKeyBySession[id]; stableID != "" {
		r.noteIdentityVersionLocked(stableID, version)
	}
}

// IsSupersededDisconnectFlush reports whether a disconnect-flush strike
// (statusCode 502) attributed to sessionID comes from a session that was
// dropped at or before its stable identity's most recent version-changed
// reset — a strike the reset would have removed had the consumer recorded it
// first. The api layer discards such a strike before it reaches any tracker.
// Anything else — a live session, a session the registry never dated (no
// stable identity at disconnect), an identity that has never reset, or a drop
// that happened after the last reset — is not superseded and records as usual,
// which keeps the once-per-interval throttle intact: a throttled version
// change stamps no new reset, so the strikes of the session that died after
// the consumed reset still land.
func (r *Registry) IsSupersededDisconnectFlush(sessionID string, statusCode int) bool {
	if statusCode != disconnectFlushStatusCode || sessionID == "" {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.supersededDisconnectFlushLocked(sessionID)
}

// supersededDisconnectFlushLocked is IsSupersededDisconnectFlush's check under
// r.mu (either mode): read-only against disconnectedStableIDs and
// identityVersionResetAt.
func (r *Registry) supersededDisconnectFlushLocked(sessionID string) bool {
	if _, live := r.providers[sessionID]; live {
		return false
	}
	c, ok := r.disconnectedStableIDs[sessionID]
	if !ok || c.id == "" {
		return false
	}
	resetAt, ok := r.identityVersionResetAt[c.id]
	return ok && !resetAt.Before(c.at)
}

// noteIdentityVersionLocked records the binary version now running under a
// stable identity and clears the identity's disconnect-flush strikes when it
// differs from the last version seen. A first observation only records.
// Caller holds r.mu.
func (r *Registry) noteIdentityVersionLocked(stableID, version string) {
	if stableID == "" || version == "" {
		return
	}
	if r.identityVersions == nil {
		r.identityVersions = make(map[string]string)
	}
	now := time.Now()
	r.pruneIdentityVersionsLocked(now)
	prev, seen := r.identityVersions[stableID]
	r.identityVersions[stableID] = version
	r.touchIdentityVersionLocked(stableID, now)
	if !seen || prev == version {
		return
	}
	if r.identityVersionResetAt == nil {
		r.identityVersionResetAt = make(map[string]time.Time)
	}
	if last, ok := r.identityVersionResetAt[stableID]; ok && now.Sub(last) < identityVersionResetMinInterval {
		r.logger.Warn("provider version changed again within the reset interval: disconnect-flush strikes retained",
			"stable_id", stableID, "previous_version", prev, "version", version, "since_last_reset", now.Sub(last))
		return
	}
	r.identityVersionResetAt[stableID] = now
	if r.clearDisconnectFlushStrikesLocked(stableID, now) {
		r.logger.Info("provider reconnected on a new binary version: disconnect-flush strikes cleared from its fault trackers",
			"stable_id", stableID, "previous_version", prev, "version", version)
	}
}

// noteInferenceFlushStrikeLocked tags one inference-error strike as a
// disconnect flush so the version reset can remove exactly that strike later.
// Caller holds r.mu; key is already stable-keyed.
func (r *Registry) noteInferenceFlushStrikeLocked(key inferenceErrorKey, at time.Time) {
	if r.inferenceErrorFlushStrikes == nil {
		r.inferenceErrorFlushStrikes = make(map[inferenceErrorKey][]time.Time)
	}
	if len(r.inferenceErrorFlushStrikes) > 1024 {
		for k := range r.inferenceErrorFlushStrikes {
			if _, live := r.inferenceErrorStrikes[k]; !live {
				delete(r.inferenceErrorFlushStrikes, k)
			}
		}
	}
	r.inferenceErrorFlushStrikes[key] = append(r.inferenceErrorFlushStrikes[key], at)
}

// pruneInferenceFlushStrikesLocked drops the key's flush tags that have left
// the breaker window, mirroring RecordInferenceError's slide of the main
// strike list so a tag never outlives the strike it marks. Deletes the key
// when nothing remains. Caller holds r.mu; key is already stable-keyed.
func (r *Registry) pruneInferenceFlushStrikesLocked(key inferenceErrorKey, now time.Time) {
	flush, ok := r.inferenceErrorFlushStrikes[key]
	if !ok {
		return
	}
	kept := flush[:0]
	for _, ts := range flush {
		if now.Sub(ts) < inferenceErrorWindow {
			kept = append(kept, ts)
		}
	}
	if len(kept) == 0 {
		delete(r.inferenceErrorFlushStrikes, key)
		return
	}
	r.inferenceErrorFlushStrikes[key] = kept
}

// clearDisconnectFlushStrikesLocked removes the disconnect-flush (502)
// strikes recorded under stableID from the inference-error breaker, the
// node-health breaker, and the health-ejection window, then re-evaluates each
// quarantine against the remaining history: one that no longer meets its own
// trip condition closes (trip counters reset so the next genuine fault does
// not re-arm as a half-open probe); one still justified by other faults stays.
// Returns whether anything was removed. Caller holds r.mu.
func (r *Registry) clearDisconnectFlushStrikesLocked(stableID string, now time.Time) (cleared bool) {
	// Inference-error breaker: (identity, model, shape) buckets.
	for key, flush := range r.inferenceErrorFlushStrikes {
		if key.ProviderID != stableID {
			continue
		}
		delete(r.inferenceErrorFlushStrikes, key)
		if len(flush) == 0 {
			continue
		}
		strikes := r.inferenceErrorStrikes[key]
		kept := make([]time.Time, 0, len(strikes))
		for _, ts := range strikes {
			if !containsTimestamp(flush, ts) {
				kept = append(kept, ts)
			}
		}
		if len(kept) == len(strikes) {
			continue
		}
		cleared = true
		if len(kept) == 0 {
			delete(r.inferenceErrorStrikes, key)
		} else {
			r.inferenceErrorStrikes[key] = kept
		}
		inWindow := 0
		for _, ts := range kept {
			if now.Sub(ts) < inferenceErrorWindow {
				inWindow++
			}
		}
		if inWindow < inferenceErrorThreshold {
			delete(r.inferenceErrorCooldowns, key)
		}
	}

	// Node-health breaker.
	if w := r.providerOutcomes[stableID]; w != nil && w.dropFlushFaults() {
		cleared = true
		total, fails := w.windowStats(now, providerBreakerWindow)
		rateTrip := total >= providerBreakerMinVolume && float64(fails) > providerBreakerFailRate*float64(total)
		if w.consecFail < providerBreakerConsecTrip && !rateTrip {
			delete(r.providerBreakerOpenUntil, stableID)
			delete(r.providerBreakerTrips, stableID)
		}
	}

	// Stable-identity health ejection (fault path only: a capacity-streak
	// ejection was never fed by 502s and is left alone).
	if w := r.healthEjectionWindows[stableID]; w != nil && w.dropFlushFaults() {
		cleared = true
		total, fails := w.windowStats(now, healthEjectionWindow)
		rateTrip := total >= healthEjectionMinSample &&
			float64(total-fails) < healthEjectionMinSuccessRate*float64(total)
		if !r.healthEjectionLastTripCapacity[stableID] &&
			w.consecFail < healthEjectionConsecTrip && !rateTrip {
			delete(r.healthEjectionUntil, stableID)
			delete(r.healthEjectionTrips, stableID)
			delete(r.healthEjectionLastTripCapacity, stableID)
		}
	}
	return cleared
}

// dropFlushFaults rebuilds the ring without its disconnect-flush faults and
// recomputes consecFail as the remaining tail's trailing fault run. Returns
// whether any entry was dropped.
func (w *providerHealthWindow) dropFlushFaults() (dropped bool) {
	entries := w.chronological()
	kept := entries[:0]
	for _, o := range entries {
		if o.flush {
			dropped = true
			continue
		}
		kept = append(kept, o)
	}
	if !dropped {
		return false
	}
	*w = providerHealthWindow{}
	for _, o := range kept {
		w.outcomes[w.head] = o
		w.head = (w.head + 1) % providerHealthRingSize
		w.size++
		if o.ok {
			w.consecFail = 0
		} else {
			w.consecFail++
		}
	}
	return true
}

// containsTimestamp reports whether ts equals any entry in list. Flush strikes
// are appended with the exact time.Time value the main strike list received,
// so equality identifies the same strike.
func containsTimestamp(list []time.Time, ts time.Time) bool {
	for _, t := range list {
		if t.Equal(ts) {
			return true
		}
	}
	return false
}
