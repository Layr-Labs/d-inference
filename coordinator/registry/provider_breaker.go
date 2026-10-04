package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RecordProviderOutcome records a terminal against the session's identity gate.
func (r *Registry) RecordProviderOutcome(providerID string, ok bool, statusCode int, errStr string, causes ...protocol.CoordinatorInferenceErrorCause) (opened, closed bool) {
	return r.gates.RecordProviderOutcome(providerID, ok, statusCode, errStr, causes...)
}

// ProviderBreakerOpen reports whether the node-health breaker is open.
func (r *Registry) ProviderBreakerOpen(providerID string) bool {
	return r.gates.ProviderBreakerOpen(providerID)
}
