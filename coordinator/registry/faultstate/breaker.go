package faultstate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Per-provider (node-health) circuit breaker.
//
// SEPARATE from and ADDITIONAL to the shape-keyed inference-error breaker in
// error_cooldown.go. That breaker is keyed by (provider, model, shape) and only
// counts sickness-shaped 500/502/504 — it deliberately ignores 503 (the
// provider's capacity/lifecycle signal) and resets per shape on success. The
// hole it leaves: a NODE that has gone bad at the box level and returns a
// GENUINE-FAULT 503 (an internal error, a crashed/panicked backend, or the
// opaque Foundation "the operation couldn't be completed" string) for ~100% of
// its requests stays fully routable. Reputation skips 503,
// the dispatch-load cooldown only fires on model-load failures, and within-
// request retry is per-request. Worse, the bad node keeps reporting slot_state
// = idle + a warm model, so the scheduler treats it as an ideal instant-TTFT
// target and keeps feeding it (one box failed 99/99 for 15+ minutes in prod).
//
// This breaker is keyed by NODE only (across every model and shape), via the
// stable fault key (faultKeyForSession: serial/SE-key when attestation has bound
// one, the session id otherwise) so its state survives reconnect churn: a
// node returning faults for ~all requests is sick regardless of cause, so it is
// quarantined fleet-wide, re-probed after an exponential cooldown, and
// auto-re-admitted on the first success.
//
// FAIL OPEN. Capacity-class sheds NEVER count (4xx/429 and a healthy-but-busy
// 5xx — token budget, KV headroom, draining, queue full, …), so load alone can
// never trip it. And when the breaker would deroute EVERY provider for a model
// (e.g. a bad fleet-wide rollout that fault-503s everywhere), selection re-scans
// with the breaker bypassed (see selectBestCandidateLockedFull) so routing can
// never be zeroed out — mirroring servability.go's fail-open philosophy.
//
// State lives on the identity's gateState (state.go) under gate.mu; the
// old opportunistic >1024 map sweep is the periodic gate sweep. The
// transition-bool return mirrors error_cooldown.go.
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

// RecordProviderOutcome feeds one provider terminal into the node-health
// breaker. ok reports whether the request ultimately succeeded; statusCode and
// errStr describe the failure when ok is false. It returns opened=true ONLY on
// the transition into quarantine and closed=true ONLY on the transition out
// (so callers emit metrics without double-counting).
//
// Classification (errStr matched case-insensitively, substring-based — provider
// strings are human-readable and drift across versions):
//   - Healthy shed (IGNORED — not recorded, consecFail/ring untouched):
//     ok==false with a client-shape code (429 or any 4xx) or a capacity-class
//     5xx (token budget / KV headroom / memory / OOM / context / draining /
//     busy slot / queue full / …). Load alone must never trip the breaker.
//   - Fault (COUNTED): 500/502/504 always; a 503 whose message indicates a real
//     fault, and — by default — any 503 not recognized as a capacity shed.
//   - Success (ok==true): clears the breaker if it had tripped.
//
// State lives on the identity's gate (state.go): keyed by the stable
// fault key (serial/SE-key when bound, session id otherwise) so it survives
// reconnect churn — a zombie that bounces its connection between faults must
// keep accumulating. Only gate.mu is taken; never r.mu.
func (r *Manager[C]) RecordProviderOutcome(providerID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (opened bool, closed bool) {
	if providerID == "" {
		return false, false
	}
	flush := !ok && isDisconnectFlush(statusCode, causes)
	var source disconnectSource[C]
	if flush {
		source = r.captureDisconnectSource(providerID)
	}
	hold := r.lockGate(r.gateForSession(providerID), "breaker")
	defer hold.unlock()
	g := hold.g
	if flush && source.supersededBy(g) {
		return false, false
	}

	now := r.now()
	defer g.updatedLocked(now)

	// SUCCESS: a served request proves the node is healthy. Record it, reset the
	// consecutive-fault counter, and CLOSE the breaker (clearing the exponential
	// backoff) if it had ever tripped — this is the auto-re-admit on recovery.
	if ok {
		g.healthWindowLocked().record(true, now)
		if !g.breakerUntil.IsZero() {
			g.breakerUntil = time.Time{}
			g.breakerTrips = 0
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
	w := g.healthWindowLocked()
	w.recordFault(now, flush)

	// Already open: the gate is derouting new traffic. In-flight faults are
	// still recorded above, but must not re-arm until the cooldown elapses
	// (the half-open probe handles that below).
	if now.Before(g.breakerUntil) {
		return false, false
	}

	// Not currently open. Two ways to (re-)arm:
	//   - half-open: the breaker had tripped (trips>0) and its cooldown elapsed,
	//     so a probe request was allowed through and just faulted — the node is
	//     still bad, so re-arm with the next, larger backoff.
	//   - closed: trip on either the consecutive-fault or the sustained
	//     fail-rate threshold.
	trips := g.breakerTrips
	halfOpen := trips > 0
	total, fails := w.windowStats(now, providerBreakerWindow)
	rateTrip := total >= providerBreakerMinVolume && float64(fails) > providerBreakerFailRate*float64(total)
	if !halfOpen && w.consecFail < providerBreakerConsecTrip && !rateTrip {
		return false, false
	}

	g.breakerUntil = now.Add(providerBreakerBackoff(trips))
	g.breakerTrips = trips + 1
	return true, false
}

// healthWindowLocked returns the gate's node-health ring, creating it on first
// use. Caller holds g.mu.
func (g *gateState) healthWindowLocked() *providerHealthWindow {
	if g.outcomes == nil {
		g.outcomes = &providerHealthWindow{}
	}
	return g.outcomes
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

// breakerOpen reports whether routing should skip this provider because its
// node-health breaker is OPEN. True iff now is before the open expiry; once
// now >= expiry it returns false so the next request is allowed through as a
// half-open probe. Resolves the session's gate; the scan itself reads the
// cached p.gate atomically (gateState.breakerOpenAt) and never comes here.
func (r *Manager[C]) breakerOpen(providerID string, now time.Time) bool {
	return r.lookupGateForSession(providerID).breakerOpenAt(now.UnixNano())
}

// ProviderBreakerOpen reports whether the per-provider node-health breaker is
// currently quarantining the provider. Exposed for tests/observability.
func (r *Manager[C]) ProviderBreakerOpen(providerID string) bool {
	return r.breakerOpen(providerID, r.now())
}

// capacityShedMarkers are lowercased substrings that mark a 5xx as a
// healthy-but-busy CAPACITY shed rather than a fault. A provider returning any
// of these is healthy and must never be derouted by the node-health breaker —
// quarantining it would shed load exactly when the fleet is busy. Kept in sync
// in spirit with the provider's capacity/lifecycle reject vocabulary.
var capacityShedMarkers = []string{
	"token_budget",
	"kv headroom",
	"kv cache headroom",
	"insufficient kv",
	"insufficient memory",
	"out of memory",
	"context length",
	"context window",
	"draining",
	// Overload / backpressure sheds: the request was never run, so the node is
	// healthy-but-busy. Classified as capacity here for consistency with the api
	// reclassifier and the inference-error breaker, which also treat these as
	// capacity/lifecycle rather than node faults.
	"request rejected",
	"request timed out waiting for capacity",
	"queue full",
	"server busy",
	"service temporarily unavailable",
}
