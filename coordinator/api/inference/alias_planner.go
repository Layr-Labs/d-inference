package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"

// NewAliasPlanner shares the live catalog and configured model-shed policy with
// admission, including request-local first-content forecasts and hard constraints.
func (s *Owner) NewAliasPlanner() routeplan.AliasPlanner {
	return routeplan.AliasPlanner{Registry: s.registry, ModelShed: s.modelShed,
		Calibration: contextCalibration, MinDecodeTPS: s.minDecodeTPS}
}
