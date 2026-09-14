package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RecordDispatchLoadFailure delegates reconnect-resistant load-failure history
// to faultstate.Manager.RecordDispatchLoadFailure and reports a new cooldown.
func (r *Registry) RecordDispatchLoadFailure(providerID, modelID string) bool {
	return r.faults.RecordDispatchLoadFailure(providerID, modelID)
}

// ClearDispatchLoadCooldown clears one pair through
// faultstate.Manager.ClearDispatchLoadCooldown after successful work.
func (r *Registry) ClearDispatchLoadCooldown(providerID, modelID string) {
	r.faults.ClearDispatchLoadCooldown(providerID, modelID)
}

// RecordInferenceError delegates provider-fault classification and per-shape
// history to faultstate.Manager.RecordInferenceError. It reports a new cooldown;
// the optional coordinator cause identifies a synthetic disconnect flush.
func (r *Registry) RecordInferenceError(providerID, modelID string, statusCode int, shape string, causes ...protocol.CoordinatorInferenceErrorCause) (enteredCooldown bool) {
	return r.faults.RecordInferenceError(providerID, modelID, statusCode, shape, causes...)
}

// RecordInferenceSuccess clears only this model/shape through
// faultstate.Manager.RecordInferenceSuccess; other shape histories remain.
func (r *Registry) RecordInferenceSuccess(providerID, modelID, shape string) {
	r.faults.RecordInferenceSuccess(providerID, modelID, shape)
}

// InferenceErrorCooldownActive reports whether the (provider, model, shape)
// triple is currently quarantined by the inference-error circuit breaker.
func (r *Registry) InferenceErrorCooldownActive(providerID, modelID, shape string) bool {
	return r.faults.InferenceErrorCooldownActive(providerID, modelID, shape)
}

// RecordProviderOutcome delegates node-health classification and history to
// faultstate.Manager.RecordProviderOutcome. The return values report only
// transitions into and out of quarantine.
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

// RecordProviderServeOutcome retains the live health-ejection switch and
// nonempty-identity guards, then delegates to faultstate.Manager.RecordProviderServeOutcome.
// The return values report only transitions into and out of quarantine.
func (r *Registry) RecordProviderServeOutcome(stableID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	if stableID == "" || !healthEjectionEnabled() {
		return false, false
	}
	return r.faults.RecordProviderServeOutcome(stableID, ok, statusCode, errStr, causes...)
}

// RecordProviderSessionServeOutcome keeps the health-ejection and bound-identity
// guards at registry. faultstate.Manager.RecordProviderSessionServeOutcome
// validates the session history and ignores superseded disconnect flushes.
func (r *Registry) RecordProviderSessionServeOutcome(sessionID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (ejected, recovered bool) {
	if sessionID == "" || !healthEjectionEnabled() || r.faultKeyForSession(sessionID) == sessionID {
		return false, false
	}
	return r.faults.RecordProviderSessionServeOutcome(sessionID, ok, statusCode, errStr, causes...)
}
