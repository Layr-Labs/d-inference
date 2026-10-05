package inference

import (
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/providerwire"
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
func (s *Owner) resolveRequestedBuild(
	parsed map[string]any,
	requested string,
	allowedProviderSerials []string,
	policy selfRoutePolicy,
	traits registry.RequestTraits,
) (buildModel, publicModel string, rewrote, ok bool) {
	buildID, isAlias, resolved := s.registry.ResolveModelConstrainedWithTraits(
		requested, allowedProviderSerials, policy.ownerAccountID,
		policy.enabled, policy.prefer, traits)
	if !resolved {
		return "", requested, false, false
	}
	if !isAlias {
		return requested, requested, false, true
	}
	parsed["model"] = buildID
	return buildID, requested, true, true
}

// candidateProviderBody derives the provider-bound body the chat handler would
// send for candidateModel — the alias fallback build the admission preflight
// probes, or the resolved build itself — from the current parsed request:
// model rewritten, that build's catalog runtime defaults reconciled, the
// service reasoning policy applied, and (Responses surface) the input→chat
// lowering. It works on a shallow copy so parsed is never mutated, serializes
// once, and is memoized per request by providerwire.Memo.
func (s *Owner) candidateProviderBody(
	parsed map[string]any,
	runtimeDefaults inreq.ModelRuntimeDefaults,
	candidateModel string,
	serviceConsumer, reasoningProvided, isResponsesAPI bool,
) ([]byte, error) {
	return providerwire.CandidateBody(s.store, parsed, runtimeDefaults, candidateModel,
		serviceConsumer, reasoningProvided, isResponsesAPI)
}
