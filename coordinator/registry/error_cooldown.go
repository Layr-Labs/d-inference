package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// RecordInferenceError records a shape-specific provider sickness strike.
func (r *Registry) RecordInferenceError(providerID, modelID string, statusCode int, shape string, causes ...protocol.CoordinatorInferenceErrorCause) bool {
	return r.gates.RecordInferenceError(providerID, modelID, statusCode, shape, causes...)
}

// RecordInferenceSuccess clears only the successful model and shape's faults.
func (r *Registry) RecordInferenceSuccess(providerID, modelID, shape string) {
	r.gates.RecordInferenceSuccess(providerID, modelID, shape)
}

func (r *Registry) InferenceErrorCooldownActive(providerID, modelID, shape string) bool {
	return r.gates.InferenceErrorCooldownActive(providerID, modelID, shape)
}
