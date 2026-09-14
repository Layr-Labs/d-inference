package ingress

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// resolveRequestedModel maps the consumer-requested model — which may be a
// public alias like "gemma-4-26b" — to the concrete build id used for routing,
// billing, and serving, returning the public name to echo back to the consumer.
// When the request used an alias it rewrites parsed["model"] and returns an
// updated rawBody so the provider receives the concrete build. Raw build ids
// pass through unchanged (publicModel == buildModel). ok=false means the alias
// currently has no usable build; the caller should surface a model_unavailable
// error.
func (s *Controller) resolveRequestedModel(
	parsed map[string]any,
	rawBody []byte,
	requested string,
	allowedProviderSerials []string,
	policy dispatch.RoutePolicy,
	traits registry.RequestTraits,
) (buildModel, publicModel string, newRawBody []byte, ok bool) {
	buildID, isAlias, resolved := s.deps.Registry().ResolveModelConstrainedWithTraits(
		requested, allowedProviderSerials, policy.OwnerAccountID,
		policy.Enabled, policy.Prefer, traits)
	if !resolved {
		return "", requested, rawBody, false
	}
	if !isAlias {
		return requested, requested, rawBody, true
	}
	parsed["model"] = buildID
	rb, err := marshalForwardBody(parsed)
	if err != nil {
		rb = rawBody
	}
	return buildID, requested, rb, true
}

// maybeFallbackAlias keeps public aliases available during a desired-build
// saturation event. Alias resolution intentionally prefers Desired when it is
// routable, but if every desired provider is transiently full (aliasFallbackCapacity)
// or too slow to hit the TTFT ceiling (aliasFallbackTTFT) and Previous can serve,
// route this request to Previous instead of returning a fast 429 / slow stream.
// Hard constraints and permanent model-too-large failures are handled by the
// caller and do not use this fallback. The TTFT estimate for Previous is also
// returned so the caller does not need to recompute it. ttftThreshold is the
// request-local deadline pinned before admission and is only consulted in
// aliasFallbackTTFT mode.
func (s *Controller) maybeFallbackAlias(parsed map[string]any, mode aliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string) (string, int, int, int, time.Duration, bool, bool) {
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false
	}
	target, ok := s.deps.Registry().AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false
	}
	// Previous must be a real, non-shed catalog build before we probe it.
	if s.deps.ModelShed(target.Previous, publicModel) || !s.deps.Registry().IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false
	}
	// A SINGLE Previous-build probe drives both modes; the mode only decides
	// whether the probe's TTFT estimate also gates the fallback.
	candidates, rejections, tooLarge, bestTTFT, hasTTFT := s.deps.Registry().QuickCapacityCheckWithTTFTForRequest(target.Previous, estimatedPromptTokens, requestedMaxTokens, traits, requiresVision, allowedProviderSerials...)
	enforceTTFT := mode == aliasFallbackTTFT
	if candidates <= 0 || (enforceTTFT && ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold)) {
		// No fallback. TTFT mode reports the probed Previous build (the caller
		// uses it as the alternate TTFT estimate); capacity mode discards the
		// model, so keep the unchanged current build.
		failModel := currentModel
		if enforceTTFT {
			failModel = target.Previous
		}
		return failModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, false
	}
	parsed["model"] = target.Previous
	return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, true
}

// aliasFallbackMode selects the failure policy for maybeFallbackAlias.
type aliasFallbackMode int

const (
	// aliasFallbackCapacity routes to Previous whenever it has any free capacity.
	aliasFallbackCapacity aliasFallbackMode = iota
	// aliasFallbackTTFT additionally rejects Previous when its best TTFT estimate
	// would miss the per-request ceiling (ttftThreshold).
	aliasFallbackTTFT
)

func ttftTooSlow(bestTTFT time.Duration, hasTTFT bool, threshold time.Duration) bool {
	return hasTTFT && bestTTFT > threshold
}

func fasterTTFTEstimate(primaryModel string, primary time.Duration, alternateModel string, alternate time.Duration, alternateOK bool) (string, time.Duration) {
	if alternateOK && alternate < primary {
		return alternateModel, alternate
	}
	return primaryModel, primary
}

// ttftMsForRejection converts a pre-flight TTFT estimate to milliseconds for the
// rejection ledger, returning 0 when the pre-flight produced no estimate.
func ttftMsForRejection(bestTTFT time.Duration, hasTTFT bool) float64 {
	if !hasTTFT {
		return 0
	}
	return float64(bestTTFT.Milliseconds())
}
