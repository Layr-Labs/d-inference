package api

import "time"

// warm_pool_signals.go — the api-side feeders of the warm-pool demand signal,
// with the attribution series the registry cannot produce itself.
//
// The warm pool sizes capacity from spill arrivals (capacity rejects, TTFT
// misses). Those are recorded per ATTEMPT — a request retried three times is
// three arrivals — so warm_pool.spill_event{kind,attempt:first|retry} measures
// how much of the demand input is retry inflation before anyone changes the
// input itself. model_load.result{status} + model_load.duration_ms close the
// loop on the registry's planner-attributed model_load.sent.

// spillAttemptTag folds the dispatch attempt index into the two-valued
// attribution tag (constant cardinality).
func spillAttemptTag(attempt int) string {
	if attempt > 0 {
		return "attempt:retry"
	}
	return "attempt:first"
}

// recordWarmPoolCapacityReject feeds a capacity reject to the warm pool and
// counts it as a spill event. The preflight runs once per request, so its
// callers pass attempt 0.
func (s *Server) recordWarmPoolCapacityReject(model string, attempt int) {
	s.registry.RecordWarmPoolCapacityReject(model)
	s.ddIncr("warm_pool.spill_event", []string{"kind:capacity_reject", spillAttemptTag(attempt)})
}

// recordWarmPoolTTFTMiss feeds a TTFT miss to the warm pool and counts it as a
// spill event attributed to the attempt that missed.
func (s *Server) recordWarmPoolTTFTMiss(model string, duration time.Duration, attempt int) {
	s.registry.RecordWarmPoolTTFTMiss(model, duration)
	s.ddIncr("warm_pool.spill_event", []string{"kind:ttft_miss", spillAttemptTag(attempt)})
}

// recordModelLoadResult counts a terminal load_model_status and its duration.
// Duration is the time since the coordinator reserved the load (0 when the
// reservation is unknown, which the histogram then simply omits).
func (s *Server) recordModelLoadResult(model, status string, duration time.Duration) {
	s.ddIncr("model_load.result", []string{"model:" + model, "status:" + status})
	if duration > 0 {
		s.ddHistogram("model_load.duration_ms", float64(duration.Milliseconds()), []string{"model:" + model})
	}
}
