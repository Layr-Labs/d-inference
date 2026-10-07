package routeplan

import (
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type CapabilityGate struct{ registry *registry.Registry }

func NewCapabilityGate(reg *registry.Registry) *CapabilityGate { return &CapabilityGate{registry: reg} }

// Reject distinguishes permanent capability gaps from a temporarily absent or
// untrusted enforcing provider. Owner routing scopes keep the conservative 503.
func (g *CapabilityGate) Reject(w http.ResponseWriter, model, publicModel string, vision, tools, constrained bool, toolMode string, scope dispatch.Scope, allowed []string) bool {
	if vision && !scope.SelfRouteOnly && !scope.PreferOwner && !g.registry.HasVisionProviderForModel(model, allowed...) {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("model %q has no vision-capable provider available for image/video input right now", publicModel), httpx.WithParam("model")))
		return true
	}
	if tools && !scope.SelfRouteOnly && !scope.PreferOwner && !g.registry.HasToolCapableProviderForTraits(model, registry.RequestTraits{HasTools: true, ToolChoiceMode: toolMode}, allowed...) {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("no online provider for model %q supports tool calls with a healthy chat template right now", publicModel), httpx.WithParam("model")))
		return true
	}
	if constrained && !g.registry.HasToolConstraintProviderForRouting(model, scope.OwnerAccountID, scope.SelfRouteOnly, scope.PreferOwner, allowed...) {
		if !scope.SelfRouteOnly && !scope.PreferOwner && g.registry.HasProviderForModel(model, allowed...) && !g.registry.HasProviderAdvertisingToolConstraint(model, allowed...) {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
				fmt.Sprintf("inference-enforced tool_choice (required/named) is not supported for model %q", publicModel), httpx.WithParam("tool_choice")))
			return true
		}
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("model_unavailable",
			fmt.Sprintf("no online provider for model %q advertises inference-time tool_choice enforcement", publicModel), httpx.WithParam("model")))
		return true
	}
	return false
}
