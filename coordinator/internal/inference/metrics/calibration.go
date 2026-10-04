package metrics

import "github.com/eigeninference/d-inference/coordinator/registry"

// ObserveTTFTCalibration joins a committed attempt's measured first content to
// its scheduler prediction. Racing/cache-selected attempts do not train it.
func (r Reporter) ObserveTTFTCalibration(pr *registry.PendingRequest) {
	if pr == nil || pr.Timing == nil || pr.UsedBackup.Load() || pr.CacheRoutingParticipates() {
		return
	}
	firstContent := pr.FirstContentAtSafe()
	if firstContent.IsZero() || pr.Timing.DispatchedAt.IsZero() {
		return
	}
	actualMs := float64(firstContent.Sub(pr.Timing.DispatchedAt).Milliseconds())
	if actualMs <= 0 {
		return
	}
	if ratio, ok := registry.RecordTTFTObservation(pr.RequestID, pr.Attempt, actualMs); ok {
		r.Observation.Gauge("routing.ttft_calibration_ratio", ratio, []string{"model:" + pr.Model})
	}
}
