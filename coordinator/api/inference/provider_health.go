package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerhealth"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) providerHealthPolicy() providerhealth.Policy {
	return providerhealth.Policy{Registry: s.registry, Store: s.store, Observation: s.observation, Logger: s.logger}
}

func (s *Owner) noteInferenceError(providerID string, pr *registry.PendingRequest, statusCode int, errStr, errReason, terminalCause string, causes ...protocol.CoordinatorInferenceErrorCause) {
	if providerID == "" || pr == nil {
		return
	}
	s.providerHealthPolicy().RecordError(providerID, pr, statusCode, errStr, errReason, terminalCause, causes...)
}

func (s *Owner) noteInferenceSuccess(pr *registry.PendingRequest) {
	if pr == nil || pr.ProviderID == "" {
		return
	}
	s.providerHealthPolicy().Success(pr)
}
