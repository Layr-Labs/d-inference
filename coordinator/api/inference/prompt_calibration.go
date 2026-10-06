package inference

import "github.com/eigeninference/d-inference/coordinator/internal/inference/estimate"

var contextCalibration = estimate.NewContextCalibration()

func calibratedContextPromptTokens(model string, est int) int {
	return contextCalibration.ContextPromptTokens(model, est)
}

// SetPromptContextCalibrationFromEnv configures the process admission policy at
// startup. Request estimates and overrides share this same calibration object.
func SetPromptContextCalibrationFromEnv(raw string) int {
	return contextCalibration.ApplyOverride(raw)
}
