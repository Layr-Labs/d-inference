package inference

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Admission performs routing preflight using the serving owner's scan gate,
// policy, registry and rejection accounting.
type Admission struct {
	owner *Owner
}

func (s *Owner) NewAdmission() *Admission {
	return &Admission{owner: s}
}

// AdmissionRequest carries the resolved build and request-local planning inputs.
// Traits follows the current forward body; TraitsForModel also resolves lazy
// alias candidates. They must remain distinct across a fallback body refresh.
type AdmissionRequest struct {
	Model                     string
	PublicModel               string
	Stream                    bool
	EstimatedPromptTokens     int
	RequestedMaxTokens        int
	RequiresVision            bool
	HasTools                  bool
	Traits                    *registry.RequestTraits
	TraitsForModel            func(string) registry.RequestTraits
	ProviderBodyErrorForModel func(string) error
	ModelMaxContext           int
	AllowedProviderSerials    []string
	Deadline                  time.Duration
	FallbackDeadline          time.Duration
	DeadlineForWork           func(string, *protocol.PromptWork) time.Duration
	ReceivedAt                time.Time
	CachePlanForModel         func(string) registry.CachePlan
	PromptWorkForModel        func(string) *protocol.PromptWork
	Policy                    access.SelfRoutePolicy
	// RefundReservation releases the existing balance hold before a terminal
	// rejection. Free paths supply a non-nil no-op closure.
	RefundReservation func()
	// OnModelFallback refreshes the forward body after parsed["model"] changes.
	// False means the callback has already written a terminal response.
	OnModelFallback func(newModel string) bool
}

// AdmissionResult selects the final build or stops the caller after a terminal
// response (including a silent refund when the client has gone away).
type AdmissionResult struct {
	Model   string
	Handled bool
}

func (p AdmissionRequest) requestTraitsForModel(model string) registry.RequestTraits {
	if p.TraitsForModel != nil {
		return p.TraitsForModel(model)
	}
	if p.Traits != nil {
		return *p.Traits
	}
	return registry.RequestTraits{HasTools: p.HasTools}
}
