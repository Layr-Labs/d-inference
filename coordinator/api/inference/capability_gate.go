package inference

import (
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"net/http"
)

func (s *Owner) NewCapabilityGate() *routeplan.CapabilityGate {
	return routeplan.NewCapabilityGate(s.registry)
}

func (s *Owner) visionToolsFailFast(w http.ResponseWriter, model, publicModel string, requiresVision, hasTools, requiresToolConstraint bool, toolChoiceMode string, policy selfRoutePolicy, allowedProviderSerials []string) bool {
	return s.NewCapabilityGate().Reject(w, model, publicModel, requiresVision, hasTools, requiresToolConstraint, toolChoiceMode, dispatch.Scope{SelfRouteOnly: policy.enabled, PreferOwner: policy.prefer, OwnerAccountID: policy.ownerAccountID}, allowedProviderSerials)
}
