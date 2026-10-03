package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// firstContentRequest carries the same request clock, calibrated prompt work
// and exact cache plan that dispatch will use. The read-only registry preflight
// does not reserve capacity or tighten the request's physical memory budget.
// Call without a routing-scan permit: cache planning may contact a sidecar.
func (p inferenceAdmissionParams) firstContentRequest(model string, traits registry.RequestTraits) *registry.PendingRequest {
	received := p.receivedAt
	// Capture even an isolated caller's anchor before optional planning.
	if received.IsZero() {
		received = time.Now()
	}
	pr := &registry.PendingRequest{
		Model: model, EstimatedPromptTokens: p.estimatedPromptTokens,
		FirstContentPromptTokens: calibratedContextPromptTokens(model, p.estimatedPromptTokens),
		RequestedMaxTokens:       p.requestedMaxTokens, RequiresVision: p.requiresVision,
		Traits: traits, AllowedProviderSerials: p.allowedProviderSerials,
		SelfRouteOnly: p.policy.enabled, PreferOwner: p.policy.prefer,
		OwnerAccountID: p.policy.ownerAccountID,
	}
	if p.cachePlanForModel != nil {
		pr.CachePlan = p.cachePlanForModel(model)
	}
	if p.promptWorkForModel != nil {
		pr.PromptWork = p.promptWorkForModel(model)
	}
	if pr.PromptWork == nil {
		pr.PromptWork = promptwork.Heuristic(pr.FirstContentPromptTokens)
	}
	deadline := p.deadline
	if p.deadlineForWork != nil {
		deadline = p.deadlineForWork(model, pr.PromptWork)
	}
	if deadline > 0 {
		pr.FirstContentDeadline = received.Add(deadline)
	}
	if p.deadlineForWork != nil {
		fallback := p.fallbackDeadline
		if fallback <= 0 {
			// Isolated internal callers may supply only the preplanning policy.
			// Keep that token term; production supplies its context-clamped value.
			fallback = p.deadline
		}
		setPromptWorkDeadlines(pr, received, fallback, deadline)
	}
	return pr
}

func (p inferenceAdmissionParams) remainingFirstContentBudget() time.Duration {
	if p.deadline <= 0 || p.receivedAt.IsZero() {
		return p.deadline
	}
	// A positive nanosecond preserves an already-expired clock's enabled gate.
	return max(time.Nanosecond, time.Until(p.receivedAt.Add(p.deadline)))
}
