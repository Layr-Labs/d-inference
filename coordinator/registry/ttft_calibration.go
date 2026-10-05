package registry

import "github.com/eigeninference/d-inference/coordinator/internal/registry/ttftcalibration"

type ttftCalibrator struct {
	*ttftcalibration.Calibrator
}

func newTTFTCalibrator() *ttftCalibrator {
	return &ttftCalibrator{Calibrator: ttftcalibration.New(nil, nil)}
}

// The scheduler and API settlement path share this process-wide owner.
var ttftCalibration = newTTFTCalibrator()

func (c *ttftCalibrator) notePrediction(requestID string, attempt int, model, chip string, rawMs float64) {
	c.NotePrediction(requestID, attempt, model, chip, rawMs)
}

func (c *ttftCalibrator) discardPrediction(requestID string, attempt int) {
	c.DiscardPrediction(requestID, attempt)
}

func (c *ttftCalibrator) recordActual(requestID string, attempt int, actualMs float64) (float64, bool) {
	return c.RecordActual(requestID, attempt, actualMs)
}

func (c *ttftCalibrator) appliedRatio(model, chip string) float64 {
	return c.AppliedRatio(model, chip)
}

// calibratedTTFTMs corrects throughput estimates without scaling cold-load time.
func calibratedTTFTMs(snap *routingSnapshot, rawMs float64) float64 {
	return calibratedTTFTMsWithRatio(snap, rawMs, ttftCalibration.appliedRatio(snap.model, snap.chipFamily))
}

// calibratedTTFTMsWithRatio uses the exact ratio recorded by the scheduler.
func calibratedTTFTMsWithRatio(snap *routingSnapshot, rawMs float64, ratio float64) float64 {
	if rawMs <= 0 || ratio == 1.0 {
		return rawMs
	}
	penalty, _ := slotStatePenalty(snap.slotState)
	return ttftcalibration.Apply(rawMs, penalty, ratio)
}

// NoteTTFTPrediction records a raw warm-slot estimate at reserve time for the
// same process-wide join consumed by RecordTTFTObservation.
func NoteTTFTPrediction(requestID string, attempt int, model, chip string, rawMs float64) {
	ttftCalibration.notePrediction(requestID, attempt, model, chip, rawMs)
}

// RecordTTFTObservation feeds the dispatch-to-first-content latency of a
// committed, non-speculative attempt into its pending raw prediction.
func RecordTTFTObservation(requestID string, attempt int, actualMs float64) (float64, bool) {
	return ttftCalibration.recordActual(requestID, attempt, actualMs)
}

// TTFTCalibrationRatio returns the clamped chip/model fallback ratio independent
// of the live kill switch, for operational introspection.
func TTFTCalibrationRatio(model, chip string) float64 {
	return ttftCalibration.LearnedRatio(model, chip)
}

// ResetTTFTCalibration clears learned and pending calibration state. Test hook.
func ResetTTFTCalibration() {
	ttftCalibration.Reset()
}
