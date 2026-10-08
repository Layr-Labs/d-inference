package routeplan

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type AliasFallbackMode int

const (
	FallbackCapacity AliasFallbackMode = iota
	FallbackTTFT
)

// AliasPlanner probes a previous concrete build under the caller's same hard
// constraints. External planning may release a CPU scan permit; a nil query
// terminates fallback before any fleet walk when reacquisition fails.
type AliasPlanner struct {
	Registry     *registry.Registry
	ModelShed    func(string, string) bool
	Calibration  *estimate.ContextCalibration
	MinDecodeTPS float64
}

func (p AliasPlanner) Fallback(parsed map[string]any, mode AliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string, firstContentQuery ...func(string) *registry.PendingRequest) (string, int, int, int, time.Duration, bool, bool) {
	model, candidates, rejected, tooLarge, best, measured, switched, _ := p.FallbackWithDeadline(parsed, mode, publicModel, currentModel, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, traits, requiresVision, allowedProviderSerials, firstContentQuery...)
	return model, candidates, rejected, tooLarge, best, measured, switched
}

func (p AliasPlanner) FallbackWithDeadline(parsed map[string]any, mode AliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string, firstContentQuery ...func(string) *registry.PendingRequest) (string, int, int, int, time.Duration, bool, bool, bool) {
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false, false
	}
	target, ok := p.Registry.AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false, false
	}
	// Previous must be a real, non-shed catalog build before we probe it.
	if p.ModelShed(target.Previous, publicModel) || !p.Registry.IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false, false
	}
	// A SINGLE Previous-build probe drives both modes; the mode only decides
	// whether the probe's TTFT estimate also gates the fallback.
	query := (firstcontent.Preflight{EstimatedPromptTokens: estimatedPromptTokens,
		RequestedMaxTokens: requestedMaxTokens, RequiresVision: requiresVision,
		AllowedProviderSerials: allowedProviderSerials, Deadline: ttftThreshold,
		Calibration: p.Calibration}).Request(target.Previous, traits)
	query.MinDecodeTPS = p.MinDecodeTPS
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
	candidates, rejections, tooLarge, bestTTFT, hasTTFT, unreachable := p.Registry.QuickFirstContentCapacityForRequestWithDeadlines(target.Previous, query)
	enforceTTFT := mode == FallbackTTFT
	ttftLate := TTFTTooSlow(bestTTFT, hasTTFT, ttftThreshold)
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

func TTFTTooSlow(bestTTFT time.Duration, hasTTFT bool, threshold time.Duration) bool {
	return threshold > 0 && hasTTFT && bestTTFT > threshold
}
