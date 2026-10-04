package firstcontent

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/promptwork"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Preflight describes the physical request inputs and advisory planning sources.
// Planning must run without a CPU scan permit because it can contact a sidecar.
type Preflight struct {
	EstimatedPromptTokens  int
	RequestedMaxTokens     int
	RequiresVision         bool
	AllowedProviderSerials []string
	SelfRouteOnly          bool
	PreferOwner            bool
	OwnerAccountID         string
	Deadline               time.Duration
	FallbackDeadline       time.Duration
	DeadlineForWork        func(string, *protocol.PromptWork) time.Duration
	ReceivedAt             time.Time
	CachePlanForModel      func(string) registry.CachePlan
	PromptWorkForModel     func(string) *protocol.PromptWork
	Calibration            *estimate.ContextCalibration
}

func (p Preflight) Request(model string, traits registry.RequestTraits) *registry.PendingRequest {
	pr := &registry.PendingRequest{
		Model: model, EstimatedPromptTokens: p.EstimatedPromptTokens,
		FirstContentPromptTokens: p.Calibration.ContextPromptTokens(model, p.EstimatedPromptTokens),
		RequestedMaxTokens:       p.RequestedMaxTokens, RequiresVision: p.RequiresVision,
		Traits: traits, AllowedProviderSerials: p.AllowedProviderSerials,
		SelfRouteOnly: p.SelfRouteOnly, PreferOwner: p.PreferOwner, OwnerAccountID: p.OwnerAccountID,
	}
	received := p.ReceivedAt
	if p.Deadline > 0 {
		if received.IsZero() {
			received = time.Now()
		}
		pr.FirstContentDeadline = received.Add(p.Deadline)
	}
	if p.CachePlanForModel != nil {
		pr.CachePlan = p.CachePlanForModel(model)
	}
	if p.PromptWorkForModel != nil {
		pr.PromptWork = p.PromptWorkForModel(model)
	}
	if pr.PromptWork == nil {
		pr.PromptWork = promptwork.Heuristic(pr.FirstContentPromptTokens)
	}
	if p.DeadlineForWork != nil {
		fallback := p.FallbackDeadline
		if fallback <= 0 {
			fallback = p.Deadline
		}
		SetPromptWorkDeadlines(pr, received, fallback, p.DeadlineForWork(model, pr.PromptWork))
	}
	return pr
}

func (p Preflight) RemainingBudget() time.Duration {
	if p.Deadline <= 0 || p.ReceivedAt.IsZero() {
		return p.Deadline
	}
	return max(time.Nanosecond, time.Until(p.ReceivedAt.Add(p.Deadline)))
}
