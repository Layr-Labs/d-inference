package ingress

import (
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// resolveRequestedBuild maps the consumer-requested model — which may be a
// public alias like "gemma-4-26b" — to the concrete build id used for routing,
// billing, and serving, returning the public name to echo back to the consumer.
// When the request used an alias it rewrites parsed["model"] to the build and
// reports rewrote=true so the caller marks its forward body dirty; it never
// serializes (the chat handler marshals once, later). Raw build ids pass
// through unchanged (publicModel == buildModel). ok=false means the alias
// currently has no usable build; the caller should surface a model_unavailable
// error. resolveRequestedModel is the body-threading variant the generic
// handler still uses.
func (s *Controller) resolveRequestedBuild(
	parsed map[string]any,
	requested string,
	allowedProviderSerials []string,
	policy dispatch.RoutePolicy,
	traits registry.RequestTraits,
) (buildModel, publicModel string, rewrote, ok bool) {
	buildID, isAlias, resolved := s.deps.Registry().ResolveModelConstrainedWithTraits(
		requested, allowedProviderSerials, policy.OwnerAccountID,
		policy.Enabled, policy.Prefer, traits)
	if !resolved {
		return "", requested, false, false
	}
	if !isAlias {
		return requested, requested, false, true
	}
	parsed["model"] = buildID
	return buildID, requested, true, true
}
