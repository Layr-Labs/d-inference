package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RecordDispatchLoadFailure puts a provider-model pair on a routing cool-down
// after the provider rejected a dispatch with a load failure. Returns true
// when this call started a new cool-down (false when one was already live),
// so callers can emit metrics without double-counting the retry storm. Lives
// on the provider's stable-identity gate (faultstate/state.go) so the cool-down
// survives a reconnect within its TTL; takes only gate.mu.
func (r *Registry) RecordDispatchLoadFailure(providerID, modelID string) bool {
	return r.faults.RecordDispatchLoadFailure(providerID, modelID)
}

// ClearDispatchLoadCooldown removes the cool-down for one provider-model pair
// (called when the pair serves a request successfully — it can load after all).
// Runs at request completion; takes only the identity's gate.mu.
func (r *Registry) ClearDispatchLoadCooldown(providerID, modelID string) {
	r.faults.ClearDispatchLoadCooldown(providerID, modelID)
}

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
// State lives on the identity's gate (faultstate/state.go), keyed inside it by
// (model, shape); only gate.mu is taken, never r.mu.
// The optional coordinator cause tags only synthetic disconnect flushes for
// version-reset cleanup; an omitted cause preserves the fault on version change.
func (r *Registry) RecordInferenceError(providerID, modelID string, statusCode int, shape string, causes ...protocol.CoordinatorInferenceErrorCause) (enteredCooldown bool) {
	return r.faults.RecordInferenceError(providerID, modelID, statusCode, shape, causes...)
}

// RecordInferenceSuccess clears the triple's strikes AND any active cool-down
// for THIS shape only — a served request proves the pair is healthy for that
// shape, so stale same-shape strikes must not combine with a future blip to
// re-quarantine it. Crucially it does NOT touch other shapes: a clean "base"
// success must never clear accumulated "tools" strikes, otherwise a
// deterministic tool failure interleaved with text traffic could never trip
// the breaker (the original incident).
func (r *Registry) RecordInferenceSuccess(providerID, modelID, shape string) {
	r.faults.RecordInferenceSuccess(providerID, modelID, shape)
}

// InferenceErrorCooldownActive reports whether the (provider, model, shape)
// triple is currently quarantined by the inference-error circuit breaker.
func (r *Registry) InferenceErrorCooldownActive(providerID, modelID, shape string) bool {
	return r.faults.InferenceErrorCooldownActive(providerID, modelID, shape)
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
//     ok==false with a client-shape code (429 or any 4xx) or a capacity-class
//     5xx (token budget / KV headroom / memory / OOM / context / draining /
//     busy slot / queue full / …). Load alone must never trip the breaker.
//   - Fault (COUNTED): 500/502/504 always; a 503 whose message indicates a real
//     fault, and — by default — any 503 not recognized as a capacity shed.
//   - Success (ok==true): clears the breaker if it had tripped.
//
// State lives on the identity's gate (faultstate/state.go): keyed by the stable
// fault key (serial/SE-key when bound, session id otherwise) so it survives
// reconnect churn — a zombie that bounces its connection between faults must
// keep accumulating. Only gate.mu is taken; never r.mu.
func (r *Registry) RecordProviderOutcome(providerID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (opened bool, closed bool) {
	return r.faults.RecordProviderOutcome(providerID, ok, statusCode, errStr, causes...)
}

// ProviderBreakerOpen reports whether the per-provider node-health breaker is
// currently quarantining the provider. Exposed for tests/observability.
func (r *Registry) ProviderBreakerOpen(providerID string) bool {
	return r.faults.ProviderBreakerOpen(providerID)
}

// HealthEjectionOpen reports whether a stable identity is currently ejected.
// Exposed for tests/observability.
func (r *Registry) HealthEjectionOpen(stableID string) bool {
	return r.faults.HealthEjectionOpen(stableID)
}

func (r *Registry) IsSupersededDisconnectFlush(sessionID string, statusCode int, causes ...protocol.CoordinatorInferenceErrorCause) bool {
	return r.faults.IsSupersededDisconnectFlush(sessionID, statusCode, causes...)
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
// State lives on the identity's gate (faultstate/state.go), filed under the stable
// id itself; only gate.mu is taken, never r.mu.
func (r *Registry) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	if stableID == "" || !healthEjectionEnabled() {
		return false, false
	}
	return r.faults.RecordProviderServeOutcome(stableID, ok, statusCode, errStr, causes...)
}

func (r *Registry) RecordProviderSessionServeOutcome(sessionID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	if sessionID == "" || !healthEjectionEnabled() || r.faultKeyForSession(sessionID) == sessionID {
		return false, false
	}
	return r.faults.RecordProviderSessionServeOutcome(sessionID, ok, statusCode, errStr, causes...)
}
