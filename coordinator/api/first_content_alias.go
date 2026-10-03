package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// aliasFallbackMode selects the failure policy for maybeFallbackAlias.
type aliasFallbackMode int

const (
	// aliasFallbackCapacity routes to Previous whenever it has any free capacity.
	aliasFallbackCapacity aliasFallbackMode = iota
	// aliasFallbackTTFT additionally rejects Previous when its best TTFT estimate
	// would miss the per-request ceiling (ttftThreshold).
	aliasFallbackTTFT
)

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
func (s *Server) maybeFallbackAlias(parsed map[string]any, mode aliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string, firstContentQuery ...func(string) *registry.PendingRequest) (string, int, int, int, time.Duration, bool, bool) {
	model, candidates, rejected, tooLarge, best, measured, switched, _ := s.maybeFallbackAliasWithDeadline(parsed, mode, publicModel, currentModel, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, traits, requiresVision, allowedProviderSerials, firstContentQuery...)
	return model, candidates, rejected, tooLarge, best, measured, switched
}

func (s *Server) maybeFallbackAliasWithDeadline(parsed map[string]any, mode aliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string, firstContentQuery ...func(string) *registry.PendingRequest) (string, int, int, int, time.Duration, bool, bool, bool) {
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false, false
	}
	target, ok := s.registry.AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false, false
	}
	// Previous must be a real, non-shed catalog build before we probe it.
	if s.modelShed(target.Previous, publicModel) || !s.registry.IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false, false
	}
	// A SINGLE Previous-build probe drives both modes; the mode only decides
	// whether the probe's TTFT estimate also gates the fallback.
	query := inferenceAdmissionParams{estimatedPromptTokens: estimatedPromptTokens,
		requestedMaxTokens: requestedMaxTokens, requiresVision: requiresVision,
		allowedProviderSerials: allowedProviderSerials, deadline: ttftThreshold}.firstContentRequest(target.Previous, traits)
	query.MinDecodeTPS = s.minDecodeTPS
	if len(firstContentQuery) > 0 && firstContentQuery[0] != nil {
		query = firstContentQuery[0](target.Previous)
		if query == nil {
			// Preflight may release its CPU scan permit for external prompt
			// planning. Failed reacquisition aborts before any fallback walk.
			return currentModel, 0, 0, 0, 0, false, false, false
		}
		// Candidate-specific exact accounting may correct the token term.
		// Use that candidate's remaining ingress-anchored budget for this gate.
		ttftThreshold = 0
		if !query.FirstContentDeadline.IsZero() {
			ttftThreshold = max(time.Nanosecond, time.Until(query.FirstContentDeadline))
		}
	}
	candidates, rejections, tooLarge, bestTTFT, hasTTFT, unreachable := s.registry.QuickFirstContentCapacityForRequestWithDeadlines(target.Previous, query)
	enforceTTFT := mode == aliasFallbackTTFT
	ttftLate := ttftTooSlow(bestTTFT, hasTTFT, ttftThreshold)
	if !query.FirstContentFallbackDeadline.IsZero() {
		ttftLate = unreachable
	}
	if candidates <= 0 || (enforceTTFT && ttftLate) {
		// No fallback. TTFT mode reports the probed Previous build (the caller
		// uses it as the alternate TTFT estimate); capacity mode discards the
		// model, so keep the unchanged current build.
		failModel := currentModel
		if enforceTTFT {
			failModel = target.Previous
		}
		return failModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, false, unreachable
	}
	parsed["model"] = target.Previous
	return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, true, unreachable
}
