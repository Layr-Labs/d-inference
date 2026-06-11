package registry

import "time"

// Inference-error circuit breaker.
//
// Prod incident: a deterministic provider-side bug (Gemma chat-template render
// crashing with "upper filter requires string" on OpenAI tool schemas) failed
// every request on affected binaries. The coordinator retried, but each retry
// landed on another provider with the SAME bug and the request died after N
// attempts anyway. The breaker quarantines a provider-model pair after repeated
// provider-side (5xx) errors so routing falls to other providers — and, paired
// with version-diverse retry, to other binary versions.
//
// Modeled on dispatchLoadCooldowns (registry.go): same key shape
// ("providerID:modelID"), same r.mu discipline, same opportunistic map
// bounding. Only sickness-shaped status codes (500/502/504) count toward
// quarantine: 4xx are client-shape failures (bad request, context too long)
// and 503 is the provider's capacity/lifecycle signal (token budget, request
// rejected, update drain) — the provider is healthy in both cases.
const (
	// inferenceErrorThreshold is how many provider-side (5xx) inference errors
	// within inferenceErrorWindow put a provider-model pair into cool-down.
	inferenceErrorThreshold = 2
	// inferenceErrorWindow is the sliding window over which strikes count.
	// Strikes older than this never contribute to the threshold.
	inferenceErrorWindow = 60 * time.Second
	// inferenceErrorCooldownTTL is how long routing skips a pair after it
	// trips the breaker — long enough to stop deterministic-failure retry
	// churn, short enough that a transiently-unlucky provider returns on its
	// own even without a served request.
	inferenceErrorCooldownTTL = 5 * time.Minute
)

// RecordInferenceError records a provider-side inference failure for the
// provider-model pair. Only statusCodes that indicate provider SICKNESS
// count as strikes:
//
//	500 — provider bug / crash-adjacent backend failure
//	502 — disconnect flush (registry.Disconnect fails pending requests as 502)
//	504 — accepted the request, then went silent
//
// Everything else records nothing and returns false. In particular 503 is a
// capacity/lifecycle signal, never sickness: the Swift provider returns 503
// for tokenBudgetExhausted / requestRejected / update-drain — healthy-but-busy
// states — and counting those would quarantine providers exactly when the
// fleet is under load. 4xx are client-shape errors (bad request, context too
// long) from a healthy provider, and other unattributed 5xx are skipped
// rather than guessed at. When the pair accumulates inferenceErrorThreshold
// strikes inside the sliding inferenceErrorWindow it enters cool-down for
// inferenceErrorCooldownTTL; further strikes while cooling extend the expiry.
// Returns true ONLY on the transition into cool-down so callers can emit
// metrics without double-counting (mirrors RecordDispatchLoadFailure).
func (r *Registry) RecordInferenceError(providerID, modelID string, statusCode int) (enteredCooldown bool) {
	switch statusCode {
	case 500, 502, 504:
		// Provider-sickness shapes: count the strike.
	default:
		return false
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()

	// Opportunistic sweep, mirroring dispatchLoadCooldowns: provider ids are
	// per-session UUIDs, so dead entries never get re-keyed — bound both maps
	// by dropping expired ones once they grow.
	if len(r.inferenceErrorCooldowns) > 1024 {
		for key, expiry := range r.inferenceErrorCooldowns {
			if !now.Before(expiry) {
				delete(r.inferenceErrorCooldowns, key)
			}
		}
	}
	if len(r.inferenceErrorStrikes) > 1024 {
		for key, strikes := range r.inferenceErrorStrikes {
			if len(strikes) == 0 || !strikes[len(strikes)-1].Add(inferenceErrorWindow).After(now) {
				delete(r.inferenceErrorStrikes, key)
			}
		}
	}

	key := providerID + ":" + modelID

	// Slide the window: keep only strikes still inside it, then add this one.
	strikes := r.inferenceErrorStrikes[key]
	kept := strikes[:0]
	for _, ts := range strikes {
		if now.Sub(ts) < inferenceErrorWindow {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	r.inferenceErrorStrikes[key] = kept

	if len(kept) < inferenceErrorThreshold {
		return false
	}

	expiry, active := r.inferenceErrorCooldowns[key]
	active = active && now.Before(expiry)
	// Threshold met: (re-)arm the cool-down. Repeated failures extend an
	// active cool-down, but only the transition reports true.
	r.inferenceErrorCooldowns[key] = now.Add(inferenceErrorCooldownTTL)
	return !active
}

// RecordInferenceSuccess clears the pair's strikes AND any active cool-down —
// a served request proves the pair is healthy, so stale strikes must not
// combine with a future blip to re-quarantine it.
func (r *Registry) RecordInferenceSuccess(providerID, modelID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := providerID + ":" + modelID
	delete(r.inferenceErrorStrikes, key)
	delete(r.inferenceErrorCooldowns, key)
}

// InferenceErrorCooldownActive reports whether the provider-model pair is
// currently quarantined by the inference-error circuit breaker.
func (r *Registry) InferenceErrorCooldownActive(providerID, modelID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.inferenceErrorCooldownActiveLocked(providerID, modelID, time.Now())
}

// inferenceErrorCooldownActiveLocked reports whether routing should skip the
// pair. READ-ONLY (no lazy delete) — some callers hold only r.mu.RLock. Caller
// holds r.mu in either mode (mirrors dispatchLoadCooldownActiveLocked).
func (r *Registry) inferenceErrorCooldownActiveLocked(providerID, modelID string, now time.Time) bool {
	expiry, ok := r.inferenceErrorCooldowns[providerID+":"+modelID]
	return ok && now.Before(expiry)
}
