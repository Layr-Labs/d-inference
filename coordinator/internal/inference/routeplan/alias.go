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
	if publicModel == "" || publicModel == currentModel {
		return currentModel, 0, 0, 0, 0, false, false
	}
	target, ok := p.Registry.AliasTarget(publicModel)
	if !ok || target.Desired != currentModel || target.Previous == "" {
		return currentModel, 0, 0, 0, 0, false, false
	}
	if p.ModelShed(target.Previous, publicModel) || !p.Registry.IsModelInCatalog(target.Previous) {
		return currentModel, 0, 0, 0, 0, false, false
	}
	query := (firstcontent.Preflight{EstimatedPromptTokens: estimatedPromptTokens,
		RequestedMaxTokens: requestedMaxTokens, RequiresVision: requiresVision,
		AllowedProviderSerials: allowedProviderSerials, Deadline: ttftThreshold,
		Calibration: p.Calibration}).Request(target.Previous, traits)
	query.MinDecodeTPS = p.MinDecodeTPS
	if len(firstContentQuery) > 0 && firstContentQuery[0] != nil {
		query = firstContentQuery[0](target.Previous)
		if query == nil {
			return currentModel, 0, 0, 0, 0, false, false
		}
	}
	candidates, rejections, tooLarge, bestTTFT, hasTTFT := p.Registry.QuickFirstContentCapacityForRequest(target.Previous, query)
	enforceTTFT := mode == FallbackTTFT
	if candidates <= 0 || (enforceTTFT && TTFTTooSlow(bestTTFT, hasTTFT, ttftThreshold)) {
		failModel := currentModel
		if enforceTTFT {
			failModel = target.Previous
		}
		return failModel, candidates, rejections, tooLarge, bestTTFT, hasTTFT, false
	}
	parsed["model"] = target.Previous
	return target.Previous, candidates, rejections, tooLarge, bestTTFT, hasTTFT, true
}

func TTFTTooSlow(bestTTFT time.Duration, hasTTFT bool, threshold time.Duration) bool {
	return threshold > 0 && hasTTFT && bestTTFT > threshold
}
