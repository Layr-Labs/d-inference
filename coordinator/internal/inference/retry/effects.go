package retry

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Effects keeps provider health, attempt-only refunds and pre-content discard
// together. The request owner retains the refund authority for every path.
type Effects struct {
	Observation *observation.Owner
	RecordError func(string, *registry.PendingRequest, int, string, string, string, ...protocol.CoordinatorInferenceErrorCause)
	RefundExtra func(*registry.PendingRequest)
}

func (e *Effects) ProviderError(provider *registry.Provider, pr *registry.PendingRequest, status int, text, reason, cause string, held *[]string, coordinatorCauses ...protocol.CoordinatorInferenceErrorCause) bool {
	if failure.IsProviderHealthNeutralErrorReason(reason) {
		provider = nil
	}
	return e.RecordProviderError(provider, pr, status, text, reason, cause, held, coordinatorCauses...)
}

// RecordProviderError is also used by endpoints with no dispatch ladder. Their
// existing health classification remains in the owner's RecordError authority.
func (e *Effects) RecordProviderError(provider *registry.Provider, pr *registry.PendingRequest, status int, text, reason, cause string, held *[]string, coordinatorCauses ...protocol.CoordinatorInferenceErrorCause) bool {
	if provider != nil {
		e.RecordError(provider.ID, pr, status, text, reason, cause, coordinatorCauses...)
	}
	e.RefundExtra(pr)
	if held == nil || len(*held) == 0 {
		return false
	}
	*held = nil
	e.Observation.Incr("inference.dispatches", []string{"status:retry_precontent"})
	return true
}

func (e *Effects) Retry(provider *registry.Provider, pr *registry.PendingRequest, status int, text, reason, cause string, held *[]string, coordinatorCauses ...protocol.CoordinatorInferenceErrorCause) {
	if !e.ProviderError(provider, pr, status, text, reason, cause, held, coordinatorCauses...) {
		e.Observation.Incr("inference.dispatches", []string{"status:retry"})
	}
}
