package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
// SHAPE-KEYED. The breaker is keyed by (provider, model, shape) — the
// provider's gate is its STABLE fault key (faultKeyForSession: serial/SE-key
// when bound, session id otherwise), so strikes and cooldowns survive
// reconnect churn, and inside the gate a modelShapeKey names the bucket. Shape ("tools" / "base", from
// RequestTraits.CooldownShape) closes the root bug behind the prod incident: a
// deterministic tool/template failure that fails EVERY tool request can be
// interleaved with clean non-tool text successes for the same pair. With a
// shared counter, each text success reset the pair's strikes, so the tool
// failures never accumulated to the 2-strike threshold and the broken provider
// was never quarantined for tools. Per-shape buckets make tool failures
// accumulate in the "tools" bucket independent of "base" successes, and a
// success clears ONLY its own shape bucket. The struct key also closes the
// threat-model colon-collision note (a model id containing ':' could alias a
// different pair under the old concat key).
//
// Modeled on the dispatch-load cooldown (model_loading.go): per-identity gate
// state (gate_state.go), window-rebuild-on-write. Only sickness-shaped
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

// RecordInferenceError records a provider-side inference failure for the
// (provider, model, shape) triple. Only statusCodes that indicate provider
// SICKNESS count as strikes:
//
//	500 — provider bug / crash-adjacent backend failure
//	502 — provider failure or an explicitly marked coordinator disconnect flush
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
//
// State lives on the identity's gate (gate_state.go), keyed inside it by
// (model, shape); only gate.mu is taken, never r.mu.
// The optional coordinator cause tags only synthetic disconnect flushes for
// version-reset cleanup; an omitted cause preserves the fault on version change.
func (r *Registry) RecordInferenceError(providerID, modelID string, statusCode int, shape string, causes ...protocol.CoordinatorInferenceErrorCause) (enteredCooldown bool) {
	switch statusCode {
	case 500, 502, 504:
		// Provider-sickness shapes: count the strike.
	default:
		return false
	}

	flush := isDisconnectFlush(statusCode, causes)
	var source disconnectSource
	if flush {
		source = r.captureDisconnectSource(providerID)
	}
	hold := r.lockGate(r.gateForSession(providerID), "inference_error")
	defer hold.unlock()
	g := hold.g
	if flush && source.supersededBy(g) {
		return false
	}

	now := time.Now()
	defer g.updatedLocked(now)

	key := modelShapeKey{Model: modelID, Shape: shape}

	// Slide the window: keep only strikes still inside it, then add this one.
	strikes := g.inferenceErrorStrikes[key]
	kept := strikes[:0]
	for _, ts := range strikes {
		if now.Sub(ts) < inferenceErrorWindow {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	g.inferenceErrorStrikes[key] = kept
	g.pruneInferenceFlushStrikesLocked(key, now)
	if flush {
		g.noteInferenceFlushStrikeLocked(key, now)
	}

	if len(kept) < inferenceErrorThreshold {
		return false
	}

	expiry, active := g.inferenceErrorCooldowns[key]
	active = active && now.Before(expiry)
	// Threshold met: (re-)arm the cool-down. Repeated failures extend an
	// active cool-down, but only the transition reports true.
	g.inferenceErrorCooldowns[key] = now.Add(inferenceErrorCooldownTTL)
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
	hold := r.lockGate(r.lookupSessionGateRef(providerID), "inference_success")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return
	}

	key := modelShapeKey{Model: modelID, Shape: shape}
	delete(g.inferenceErrorStrikes, key)
	delete(g.inferenceErrorCooldowns, key)
	delete(g.inferenceErrorFlushStrikes, key)
	g.updatedLocked(time.Now())
}

// InferenceErrorCooldownActive reports whether the (provider, model, shape)
// triple is currently quarantined by the inference-error circuit breaker.
func (r *Registry) InferenceErrorCooldownActive(providerID, modelID, shape string) bool {
	return r.inferenceErrorCooled(providerID, modelID, shape, time.Now())
}

// inferenceErrorCooled reports whether routing should skip the triple.
// Resolves the session's gate; the scan uses the cached p.gate directly.
func (r *Registry) inferenceErrorCooled(providerID, modelID, shape string, now time.Time) bool {
	return r.lookupGateForSession(providerID).inferenceErrorCooled(modelID, shape, now)
}

// inferenceErrorCooled is the gate-level check: lock-free "no cooldown on any
// shape" fast path, otherwise one short gate.mu section. READ-ONLY (no lazy
// delete). nil-safe.
func (g *gateState) inferenceErrorCooled(modelID, shape string, now time.Time) bool {
	if !g.hasPairState(gateFlagErrorCooldown) {
		return false
	}
	g = g.lockResolved()
	expiry, ok := g.inferenceErrorCooldowns[modelShapeKey{Model: modelID, Shape: shape}]
	g.mu.Unlock()
	return ok && now.Before(expiry)
}
