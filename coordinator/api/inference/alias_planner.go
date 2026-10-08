package inference

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// NewAliasPlanner shares the live catalog and configured model-shed policy with
// admission, including request-local first-content forecasts and hard constraints.
func (s *Owner) NewAliasPlanner() routeplan.AliasPlanner {
	return routeplan.AliasPlanner{Registry: s.registry, ModelShed: s.modelShed,
		Calibration: contextCalibration, MinDecodeTPS: s.minDecodeTPS}
}

func (s *Owner) maybeFallbackAliasWithDeadline(parsed map[string]any, mode aliasFallbackMode, publicModel, currentModel string, estimatedPromptTokens, requestedMaxTokens int, ttftThreshold time.Duration, traits registry.RequestTraits, requiresVision bool, allowedProviderSerials []string, firstContentQuery ...func(string) *registry.PendingRequest) (string, int, int, int, time.Duration, bool, bool, bool) {
	return s.NewAliasPlanner().FallbackWithDeadline(parsed, mode, publicModel, currentModel, estimatedPromptTokens, requestedMaxTokens, ttftThreshold, traits, requiresVision, allowedProviderSerials, firstContentQuery...)
}
