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
// SHAPE-KEYED. The breaker is keyed by (provider, model, shape) rather than a
// "providerID:modelID" string. Shape ("tools" / "base", from
// RequestTraits.CooldownShape) closes the root bug behind the prod incident: a
// deterministic tool/template failure that fails EVERY tool request can be
// interleaved with clean non-tool text successes for the same pair. With a
// shared counter, each text success reset the pair's strikes, so the tool
// failures never accumulated to the 2-strike threshold and the broken provider
// was never quarantined for tools. Per-shape buckets make tool failures
// accumulate in the "tools" bucket independent of "base" successes, and a
// success clears ONLY its own shape bucket. The struct key also closes the
// threat-model colon-collision note (a provider/model id containing ':' could
// alias a different pair under the old concat key).
//
// Modeled on dispatchLoadCooldowns (registry.go): same r.mu discipline, same
// opportunistic map bounding, window-rebuild-on-write. Only sickness-shaped
// status codes (500/502/504) count toward quarantine: 4xx are client-shape
// failures (bad request, context too long) and 503 is the provider's
// capacity/lifecycle signal (token budget, request rejected, update drain) —
// the provider is healthy in both cases.
const (
	// inferenceErrorThreshold is how many provider-side (5xx) inference errors
	// within inferenceErrorWindow put a (provider, model, shape) triple into
	// cool-down.
	inferenceErrorThreshold = 2
	// inferenceErrorWindow is the sliding window over which strikes count.
	// Strikes older than this never contribute to the threshold.
	inferenceErrorWindow = 60 * time.Second
	// inferenceErrorCooldownTTL is how long routing skips a triple after it
	// trips the breaker — long enough to stop deterministic-failure retry
	// churn, short enough that a transiently-unlucky provider returns on its
	// own even without a served request.
	inferenceErrorCooldownTTL = 5 * time.Minute
)

// inferenceErrorKey identifies a circuit-breaker bucket. Shape is the request
// dimension from RequestTraits.CooldownShape ("tools" / "base"), so a failure
// that only affects one shape quarantines only that shape. A struct key (vs a
// delimiter-joined string) cannot alias across ids that contain the delimiter.
type inferenceErrorKey struct {
	ProviderID string
	ModelID    string
	Shape      string
}

// RecordInferenceError records a provider-side inference failure for the
// (provider, model, shape) triple. Only statusCodes that indicate provider
// SICKNESS count as strikes:
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
// rather than guessed at. When the triple accumulates inferenceErrorThreshold
// strikes inside the sliding inferenceErrorWindow it enters cool-down for
// inferenceErrorCooldownTTL; further strikes while cooling extend the expiry.
// Returns true ONLY on the transition into cool-down so callers can emit
// metrics without double-counting (mirrors RecordDispatchLoadFailure).
func (r *Registry) RecordInferenceError(providerID, modelID string, statusCode int, shape string) (enteredCooldown bool) {
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

	key := inferenceErrorKey{ProviderID: providerID, ModelID: modelID, Shape: shape}

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

// RecordInferenceSuccess clears the triple's strikes AND any active cool-down
// for THIS shape only — a served request proves the pair is healthy for that
// shape, so stale same-shape strikes must not combine with a future blip to
// re-quarantine it. Crucially it does NOT touch other shapes: a clean "base"
// success must never clear accumulated "tools" strikes, otherwise a
// deterministic tool failure interleaved with text traffic could never trip
// the breaker (the original incident).
func (r *Registry) RecordInferenceSuccess(providerID, modelID, shape string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := inferenceErrorKey{ProviderID: providerID, ModelID: modelID, Shape: shape}
	delete(r.inferenceErrorStrikes, key)
	delete(r.inferenceErrorCooldowns, key)
}

// InferenceErrorCooldownActive reports whether the (provider, model, shape)
// triple is currently quarantined by the inference-error circuit breaker.
func (r *Registry) InferenceErrorCooldownActive(providerID, modelID, shape string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.inferenceErrorCooldownActiveLocked(providerID, modelID, shape, time.Now())
}

// inferenceErrorCooldownActiveLocked reports whether routing should skip the
// triple. READ-ONLY (no lazy delete) — some callers hold only r.mu.RLock.
// Caller holds r.mu in either mode (mirrors dispatchLoadCooldownActiveLocked).
func (r *Registry) inferenceErrorCooldownActiveLocked(providerID, modelID, shape string, now time.Time) bool {
	key := inferenceErrorKey{ProviderID: providerID, ModelID: modelID, Shape: shape}
	expiry, ok := r.inferenceErrorCooldowns[key]
	return ok && now.Before(expiry)
}
