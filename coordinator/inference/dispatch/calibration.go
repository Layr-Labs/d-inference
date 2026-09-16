package dispatch

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// observeTTFTCalibration feeds the online TTFT calibrator
// (registry/routingcost/calibration.go) with the committed attempt's measured
// dispatch→first-content latency — the same quantity persisted as
// actual_ttft_ms. Called from the dispatch goroutine at content commit
// (commitFirstContent), which owns pr.Timing, so DispatchedAt is safe to read
// directly and FirstContentAt has just been stamped.
//
// Speculative-race attempts (pr.UsedBackup, set on both racers before the race
// starts on this same goroutine) are excluded: the race winner is the faster
// of two draws, which would bias actuals downward. Requests with no matching
// pending prediction (cold dispatches, providers without BackendCapacity,
// retries whose prediction expired) are ignored by the calibrator itself.
func (s *Controller) observeTTFTCalibration(pr *registry.PendingRequest) {
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
		s.deps.Counters.Gauge("routing.ttft_calibration_ratio", ratio, []string{"model:" + pr.Model})
	}
}
