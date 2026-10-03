package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// findRoutableProvider selects a provider for model via the PRODUCTION routing
// path (ReserveProviderEx), releases the reserved capacity, and returns the
// selected provider — or nil when no provider can serve the model right now.
// It replaces the removed score-based registry.FindProvider as a routability
// probe in API-layer tests: routing applies the same structural/privacy/trust/
// challenge/capacity gates, so "is this routable?" assertions hold without a
// parallel routing implementation.
func findRoutableProvider(reg *registry.Registry, model string) *registry.Provider {
	pr := &registry.PendingRequest{RequestID: "test-route-probe", Model: model, RequestedMaxTokens: 64}
	p, _ := reg.ReserveProviderEx(model, pr)
	if p != nil {
		p.RemovePending(pr.RequestID)
		reg.SetProviderIdle(p.ID)
	}
	return p
}
