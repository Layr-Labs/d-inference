package routingcost

// Policy owns latency tuning and the prediction-to-observation calibration
// transaction. Configure its startup knobs before serving; only calibration is
// mutated concurrently. Its private calibration lock is a leaf: no method
// calls registry, provider or request operations while holding it.
//
// Connection is only an opaque value carried by Snapshot. Policy never
// dereferences it, so callers retain their exact connection identity fences.
// Construct a Policy with New and share it across all routing callers.
type Policy[Connection comparable] struct {
	calibration               *ttftCalibrator
	prefillToDecodeRatio      float64
	ttftOccupancyAlpha        float64
	longPromptThresholdTokens int
	longPromptPrefillWeight   float64
	ttftAdmissionMode         TTFTAdmissionMode
	ttftDeadlineBaseMs        float64
}

// New initializes the original routing defaults and empty calibration joins.
func New[Connection comparable]() *Policy[Connection] {
	return &Policy[Connection]{
		calibration:               newTTFTCalibrator(),
		prefillToDecodeRatio:      DefaultPrefillToDecodeRatio,
		ttftOccupancyAlpha:        0.0,
		longPromptThresholdTokens: DefaultLongPromptThresholdTokens,
		longPromptPrefillWeight:   DefaultLongPromptPrefillWeight,
		ttftAdmissionMode:         TTFTAdmissionOff,
		ttftDeadlineBaseMs:        DefaultTTFTDeadlineBaseMs,
	}
}

// NotePrediction records the raw warm-slot prediction for one reserved attempt.
func (policy *Policy[Connection]) NotePrediction(requestID string, attempt int, model, chip string, rawMs float64) {
	policy.calibration.notePrediction(requestID, attempt, model, chip, rawMs)
}

// DiscardPrediction removes a prediction when concrete cache preparation makes
// the text-prefill observation unsuitable for calibration.
func (policy *Policy[Connection]) DiscardPrediction(requestID string, attempt int) {
	policy.calibration.discardPrediction(requestID, attempt)
}

// AppliedRatio reads the current learned ratio, honoring the live kill switch.
func (policy *Policy[Connection]) AppliedRatio(model, chip string) float64 {
	return policy.calibration.appliedRatio(model, chip)
}
