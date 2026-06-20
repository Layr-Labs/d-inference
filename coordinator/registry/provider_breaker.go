package registry

import (
	"strings"
	"time"
)

// Per-provider (node-health) circuit breaker.
//
// SEPARATE from and ADDITIONAL to the shape-keyed inference-error breaker in
// error_cooldown.go. That breaker is keyed by (provider, model, shape) and only
// counts sickness-shaped 500/502/504 — it deliberately ignores 503 (the
// provider's capacity/lifecycle signal) and resets per shape on success. The
// hole it leaves: a NODE that has gone bad at the box level and returns a
// GENUINE-FAULT 503 ("request rejected", internal error, a crashed/panicked
// backend, or the opaque Foundation "the operation couldn't be completed"
// string) for ~100% of its requests stays fully routable. Reputation skips 503,
// the dispatch-load cooldown only fires on model-load failures, and within-
// request retry is per-request. Worse, the bad node keeps reporting slot_state
// = idle + a warm model, so the scheduler treats it as an ideal instant-TTFT
// target and keeps feeding it (one box failed 99/99 for 15+ minutes in prod).
//
// This breaker is keyed by PROVIDER only (across every model and shape): a
// node returning faults for ~all requests is sick regardless of cause, so it is
// quarantined fleet-wide, re-probed after an exponential cooldown, and
// auto-re-admitted on the first success.
//
// FAIL OPEN. Capacity-class sheds NEVER count (4xx/429 and a healthy-but-busy
// 503 — token budget, KV headroom, draining, queue full, …), so load alone can
// never trip it. And when the breaker would deroute EVERY provider for a model
// (e.g. a bad fleet-wide rollout that fault-503s everywhere), selection re-scans
// with the breaker bypassed (see selectBestCandidateLockedFull) so routing can
// never be zeroed out — mirroring servability.go's fail-open philosophy.
//
// r.mu discipline, opportunistic >1024 map sweep, and the transition-bool
// return all mirror error_cooldown.go.
const (
	// providerBreakerConsecTrip: consecutive FAULT outcomes (no success in
	// between) that open the breaker. A node failing this many in a row is
	// almost certainly sick, independent of overall volume.
	providerBreakerConsecTrip = 5
	// providerBreakerWindow is the sliding window over which the fail-rate trip
	// condition is evaluated.
	providerBreakerWindow = 120 * time.Second
	// providerBreakerMinVolume is the minimum number of outcomes inside the
	// window before the fail-rate condition can trip — avoids quarantining a
	// node on a tiny, unlucky sample.
	providerBreakerMinVolume = 20
	// providerBreakerFailRate is the fraction of windowed outcomes that must be
	// faults for the rate condition to trip (strictly greater-than).
	providerBreakerFailRate = 0.80
	// providerBreakerBaseCooldown is the first quarantine duration. Each
	// successive trip without an intervening success doubles it (capped at
	// providerBreakerMaxCooldown) so a persistently-bad node backs off fast.
	providerBreakerBaseCooldown = 60 * time.Second
	// providerBreakerMaxCooldown caps the exponential backoff.
	providerBreakerMaxCooldown = 5 * time.Minute
	// providerHealthRingSize is the fixed number of recent (fault/success)
	// outcomes retained per provider for the fail-rate computation. Healthy
	// sheds are never recorded, so the ring holds only faults and successes.
	providerHealthRingSize = 20
)

// providerHealthOutcome is one recorded terminal: ok=false is a FAULT, ok=true
// is a SUCCESS. Capacity/client sheds are never recorded.
type providerHealthOutcome struct {
	ts time.Time
	ok bool
}

// providerHealthWindow is a fixed-size ring of the most recent
// providerHealthRingSize outcomes for one provider, plus the running count of
// CONSECUTIVE faults (reset by any success). The ring backs the windowed
// fail-rate trip condition; consecFail backs the consecutive-fault condition.
type providerHealthWindow struct {
	outcomes   [providerHealthRingSize]providerHealthOutcome
	size       int // number of valid entries (saturates at providerHealthRingSize)
	head       int // index of the next write
	consecFail int // consecutive faults; reset to 0 on any success
}

// record appends one outcome to the ring and updates the consecutive-fault
// counter. Only faults and successes are recorded (callers filter healthy sheds
// out first).
func (w *providerHealthWindow) record(ok bool, now time.Time) {
	w.outcomes[w.head] = providerHealthOutcome{ts: now, ok: ok}
	w.head = (w.head + 1) % providerHealthRingSize
	if w.size < providerHealthRingSize {
		w.size++
	}
	if ok {
		w.consecFail = 0
	} else {
		w.consecFail++
	}
}

// windowStats returns the number of outcomes recorded within [now-window, now]
// and how many of those were faults.
func (w *providerHealthWindow) windowStats(now time.Time, window time.Duration) (total, fails int) {
	cutoff := now.Add(-window)
	for i := 0; i < w.size; i++ {
		o := w.outcomes[i]
		if o.ts.Before(cutoff) {
			continue
		}
		total++
		if !o.ok {
			fails++
		}
	}
	return total, fails
}

// RecordProviderOutcome feeds one provider terminal into the node-health
// breaker. ok reports whether the request ultimately succeeded; statusCode and
// errStr describe the failure when ok is false. It returns opened=true ONLY on
// the transition into quarantine and closed=true ONLY on the transition out
// (so callers emit metrics without double-counting).
//
// Classification (errStr matched case-insensitively, substring-based — provider
// strings are human-readable and drift across versions):
//   - Healthy shed (IGNORED — not recorded, consecFail/ring untouched):
//     ok==false with a client-shape code (429 or any 4xx) or a CAPACITY-class
//     503 (token budget / KV headroom / memory / OOM / context / draining /
//     busy slot / queue full / …). Load alone must never trip the breaker.
//   - Fault (COUNTED): 500/502/504 always; a 503 whose message indicates a real
//     fault, and — by default — any 503 not recognized as a capacity shed.
//   - Success (ok==true): clears the breaker if it had tripped.
func (r *Registry) RecordProviderOutcome(providerID string, ok bool, statusCode int, errStr string) (opened bool, closed bool) {
	if providerID == "" {
		return false, false
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()

	// Opportunistic sweep (mirrors error_cooldown.go): provider ids are
	// per-session UUIDs, so dead entries never get re-keyed — bound the maps by
	// dropping expired/idle entries once they grow.
	if len(r.providerBreakerOpenUntil) > 1024 {
		for id, until := range r.providerBreakerOpenUntil {
			if !now.Before(until) {
				delete(r.providerBreakerOpenUntil, id)
				delete(r.providerBreakerTrips, id)
			}
		}
	}
	if len(r.providerOutcomes) > 1024 {
		for id, w := range r.providerOutcomes {
			if total, _ := w.windowStats(now, providerBreakerWindow); total == 0 {
				delete(r.providerOutcomes, id)
			}
		}
	}

	// SUCCESS: a served request proves the node is healthy. Record it, reset the
	// consecutive-fault counter, and CLOSE the breaker (clearing the exponential
	// backoff) if it had ever tripped — this is the auto-re-admit on recovery.
	if ok {
		r.providerHealthWindowLocked(providerID).record(true, now)
		if _, had := r.providerBreakerOpenUntil[providerID]; had {
			delete(r.providerBreakerOpenUntil, providerID)
			delete(r.providerBreakerTrips, providerID)
			return false, true
		}
		return false, false
	}

	// FAILURE: ignore healthy sheds entirely — only genuine faults touch the
	// ring / consecutive-fault counter, so a busy fleet (429 / capacity-503) can
	// never be quarantined.
	if !providerOutcomeIsFault(statusCode, errStr) {
		return false, false
	}
	w := r.providerHealthWindowLocked(providerID)
	w.record(false, now)

	// Already open: the gate is derouting new traffic. In-flight faults are
	// still recorded above, but must not re-arm until the cooldown elapses
	// (the half-open probe handles that below).
	if until, had := r.providerBreakerOpenUntil[providerID]; had && now.Before(until) {
		return false, false
	}

	// Not currently open. Two ways to (re-)arm:
	//   - half-open: the breaker had tripped (trips>0) and its cooldown elapsed,
	//     so a probe request was allowed through and just faulted — the node is
	//     still bad, so re-arm with the next, larger backoff.
	//   - closed: trip on either the consecutive-fault or the sustained
	//     fail-rate threshold.
	trips := r.providerBreakerTrips[providerID]
	halfOpen := trips > 0
	total, fails := w.windowStats(now, providerBreakerWindow)
	rateTrip := total >= providerBreakerMinVolume && float64(fails) > providerBreakerFailRate*float64(total)
	if !halfOpen && w.consecFail < providerBreakerConsecTrip && !rateTrip {
		return false, false
	}

	r.providerBreakerOpenUntil[providerID] = now.Add(providerBreakerBackoff(trips))
	r.providerBreakerTrips[providerID] = trips + 1
	return true, false
}

// providerHealthWindowLocked returns the provider's health ring, creating it on
// first use. Caller holds r.mu.
func (r *Registry) providerHealthWindowLocked(providerID string) *providerHealthWindow {
	w := r.providerOutcomes[providerID]
	if w == nil {
		w = &providerHealthWindow{}
		r.providerOutcomes[providerID] = w
	}
	return w
}

// providerBreakerBackoff returns the cooldown for a provider that has already
// tripped `trips` times (0 = first trip): base * 2^trips, capped at the max. The
// loop avoids overflowing the shift for large trip counts.
func providerBreakerBackoff(trips int) time.Duration {
	cooldown := providerBreakerBaseCooldown
	for i := 0; i < trips && cooldown < providerBreakerMaxCooldown; i++ {
		cooldown *= 2
	}
	if cooldown > providerBreakerMaxCooldown {
		cooldown = providerBreakerMaxCooldown
	}
	return cooldown
}

// providerBreakerOpenLocked reports whether routing should skip this provider
// because its node-health breaker is OPEN. True iff now is before the open
// expiry; once now >= expiry it returns false so the next request is allowed
// through as a half-open probe. READ-ONLY (no lazy delete) so it is safe under
// r.mu held in either mode — mirrors inferenceErrorCooldownActiveLocked. Caller
// holds r.mu.
func (r *Registry) providerBreakerOpenLocked(providerID string, now time.Time) bool {
	until, ok := r.providerBreakerOpenUntil[providerID]
	return ok && now.Before(until)
}

// ProviderBreakerOpen reports whether the per-provider node-health breaker is
// currently quarantining the provider. Exposed for tests/observability; the
// routing hot path uses providerBreakerOpenLocked under the already-held r.mu.
func (r *Registry) ProviderBreakerOpen(providerID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.providerBreakerOpenLocked(providerID, time.Now())
}

// providerOutcomeIsFault classifies a FAILED provider terminal (ok==false) for
// the node-health breaker. It is intentionally implemented LOCALLY in the
// registry package: the api package owns the request-time failure classifier,
// and importing it here would create an import cycle (api already imports
// registry).
//
// Healthy sheds (returns false — never counted):
//   - client-shape failures: 429 and any 4xx (400-499, incl. 499 cancel)
//   - capacity-class 503: a healthy-but-busy provider (see isCapacityShed503)
//
// Genuine faults (returns true — counted toward the breaker):
//   - 500/502/504 always (provider-sickness shapes, same as the inference-error
//     breaker)
//   - a 503 whose message indicates a real fault ("request rejected", internal
//     error, model load failed, crash/panic, the opaque Foundation string) and,
//     by default, ANY 503 not recognized as a capacity shed
//
// Any other code (e.g. an unattributed 0/501/505) is NOT counted — conservative,
// matching the inference-error breaker ignoring unattributed 5xx.
func providerOutcomeIsFault(statusCode int, errStr string) bool {
	if statusCode == 429 || (statusCode >= 400 && statusCode <= 499) {
		return false
	}
	switch statusCode {
	case 500, 502, 504:
		return true
	case 503:
		return !isCapacityShed503(errStr)
	default:
		return false
	}
}

// capacityShed503Markers are lowercased substrings that mark a 503 as a
// healthy-but-busy CAPACITY shed rather than a fault. A provider returning any
// of these is healthy and must never be derouted by the node-health breaker —
// quarantining it would shed load exactly when the fleet is busy. Kept in sync
// in spirit with the provider's capacity/lifecycle 503 vocabulary.
var capacityShed503Markers = []string{
	"token_budget",
	"kv headroom",
	"kv cache headroom",
	"insufficient kv",
	"insufficient memory",
	"out of memory",
	"context length",
	"context window",
	"draining",
	"request timed out waiting for capacity",
	"queue full",
	"server busy",
	"service temporarily unavailable",
}

// isCapacityShed503 reports whether a 503's message describes a healthy-but-busy
// capacity/lifecycle shed (which must NOT count toward the breaker). Matching is
// case-insensitive and substring-based, except "oom" (whole word, so "room" /
// "bloom" do not match) and the ("slot" AND "active") pair (a busy-slot shed).
func isCapacityShed503(errStr string) bool {
	s := strings.ToLower(errStr)
	for _, m := range capacityShed503Markers {
		if strings.Contains(s, m) {
			return true
		}
	}
	if containsWord(s, "oom") {
		return true
	}
	if strings.Contains(s, "slot") && strings.Contains(s, "active") {
		return true
	}
	return false
}

// containsWord reports whether word appears in s delimited by non-word
// boundaries, so a short token like "oom" matches "gpu oom" but not "boom" or
// "room". word is assumed lowercase/alphanumeric; s is already lowercased.
// (Local to the registry package; mirrors the api package's helper of the same
// name — the two live in different packages.)
func containsWord(s, word string) bool {
	for from := 0; from+len(word) <= len(s); {
		i := strings.Index(s[from:], word)
		if i < 0 {
			return false
		}
		start := from + i
		end := start + len(word)
		beforeOK := start == 0 || !isWordByte(s[start-1])
		afterOK := end == len(s) || !isWordByte(s[end])
		if beforeOK && afterOK {
			return true
		}
		from = start + 1
	}
	return false
}

func isWordByte(b byte) bool {
	return b == '_' ||
		(b >= 'a' && b <= 'z') ||
		(b >= 'A' && b <= 'Z') ||
		(b >= '0' && b <= '9')
}
