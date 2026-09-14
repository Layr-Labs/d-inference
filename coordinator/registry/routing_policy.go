package registry

import (
	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// All registries and API observation hooks share one process-wide policy.
// Startup setters below must run before serving. Calibration owns its leaf lock.
var routingPolicy = routingcost.New[*Provider]()

type routingSnapshot = routingcost.Snapshot[*Provider]
type TTFTAdmissionMode = routingcost.TTFTAdmissionMode

const (
	TTFTAdmissionOff     = routingcost.TTFTAdmissionOff
	TTFTAdmissionShadow  = routingcost.TTFTAdmissionShadow
	TTFTAdmissionEnforce = routingcost.TTFTAdmissionEnforce
)

// SetPrefillToDecodeRatio delegates to the shared routing policy before serving starts.
func SetPrefillToDecodeRatio(ratio float64) {
	routingPolicy.SetPrefillToDecodeRatio(ratio)
}

// PrefillToDecodeRatio delegates to the shared routing policy.
func PrefillToDecodeRatio() float64 {
	return routingPolicy.PrefillToDecodeRatio()
}

// SetTTFTOccupancyAlpha delegates to the shared routing policy before serving starts.
func SetTTFTOccupancyAlpha(alpha float64) {
	routingPolicy.SetTTFTOccupancyAlpha(alpha)
}

// TTFTOccupancyAlpha delegates to the shared routing policy.
func TTFTOccupancyAlpha() float64 {
	return routingPolicy.TTFTOccupancyAlpha()
}

// SetLongPromptThreshold delegates to the shared routing policy before serving starts.
func SetLongPromptThreshold(tokens int) {
	routingPolicy.SetLongPromptThreshold(tokens)
}

// LongPromptThreshold delegates to the shared routing policy.
func LongPromptThreshold() int {
	return routingPolicy.LongPromptThreshold()
}

// SetLongPromptPrefillWeight delegates to the shared routing policy before serving starts.
func SetLongPromptPrefillWeight(w float64) {
	routingPolicy.SetLongPromptPrefillWeight(w)
}

// LongPromptPrefillWeight delegates to the shared routing policy.
func LongPromptPrefillWeight() float64 {
	return routingPolicy.LongPromptPrefillWeight()
}

// SetTTFTAdmissionMode delegates to the shared routing policy before serving starts.
func SetTTFTAdmissionMode(mode TTFTAdmissionMode) {
	routingPolicy.SetTTFTAdmissionMode(mode)
}

// TTFTAdmissionModeValue delegates to the shared routing policy.
func TTFTAdmissionModeValue() TTFTAdmissionMode {
	return routingPolicy.TTFTAdmissionModeValue()
}

// SetTTFTDeadlineBaseMs delegates to the shared routing policy before serving starts.
func SetTTFTDeadlineBaseMs(ms float64) {
	routingPolicy.SetTTFTDeadlineBaseMs(ms)
}

// TTFTDeadlineBaseMs delegates to the shared routing policy.
func TTFTDeadlineBaseMs() float64 {
	return routingPolicy.TTFTDeadlineBaseMs()
}

// RecordTTFTObservation delegates to the shared routing policy.
func RecordTTFTObservation(requestID string, attempt int, actualMs float64) (float64, bool) {
	return routingPolicy.RecordTTFTObservation(requestID, attempt, actualMs)
}

// TTFTCalibrationRatio delegates to the shared routing policy.
func TTFTCalibrationRatio(model, chip string) float64 {
	return routingPolicy.CalibrationRatio(model, chip)
}

// ResetTTFTCalibration delegates to the shared routing policy.
func ResetTTFTCalibration() {
	routingPolicy.ResetCalibration()
}

// ParseTTFTAdmissionMode parses the shared shadow policy vocabulary.
func ParseTTFTAdmissionMode(s string) TTFTAdmissionMode { return routingcost.ParseTTFTAdmissionMode(s) }
