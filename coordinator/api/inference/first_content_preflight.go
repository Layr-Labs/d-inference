package inference

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// firstContentRequest carries the same request clock, calibrated prompt work
// and exact cache plan that dispatch will use. The read-only registry preflight
// does not reserve capacity or tighten the request's physical memory budget.
// Call without a routing-scan permit: cache planning may contact a sidecar.
func (p AdmissionRequest) firstContentRequest(model string, traits registry.RequestTraits) *registry.PendingRequest {
	return p.preflightRequest().Request(model, traits)
}

func (p AdmissionRequest) remainingFirstContentBudget() time.Duration {
	return p.preflightRequest().RemainingBudget()
}

func (p AdmissionRequest) preflightRequest() firstcontent.Preflight {
	return firstcontent.Preflight{
		EstimatedPromptTokens: p.EstimatedPromptTokens, RequestedMaxTokens: p.RequestedMaxTokens,
		RequiresVision: p.RequiresVision, AllowedProviderSerials: p.AllowedProviderSerials,
		SelfRouteOnly: p.Policy.Enabled, PreferOwner: p.Policy.Prefer, OwnerAccountID: p.Policy.OwnerAccountID,
		Deadline: p.Deadline, ReceivedAt: p.ReceivedAt,
		FallbackDeadline: p.FallbackDeadline, DeadlineForWork: p.DeadlineForWork, CachePlanForModel: p.CachePlanForModel,
		PromptWorkForModel: p.PromptWorkForModel, Calibration: contextCalibration,
	}
}
