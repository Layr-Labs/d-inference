package api

// Phase-0 TTFT telemetry emission (DogStatsD + the in-process /v1/admin/metrics
// registry). These are pure observability hooks — no routing behavior changes.

// emitInvalidTTFT fires when applyPendingRouteTelemetry clamped a negative raw
// time-to-first-token to 0. It is the loud guard against any regression of the
// retried-request shared-Timing bug (FirstContentAt of an early attempt minus a
// later attempt's overwritten DispatchedAt), which produced -ms rows down to
// -378s. Emitted from the single store-submit funnel so it covers every path.
func (s *Server) emitInvalidTTFT(model, reason string) {
	if s == nil {
		return
	}
	tags := []string{"reason:" + reason}
	if model != "" {
		tags = append(tags, "model:"+model)
	}
	s.ddIncr("routing.invalid_ttft", tags)
	if s.metrics != nil {
		labels := []MetricLabel{{Name: "reason", Value: reason}}
		if model != "" {
			labels = append(labels, MetricLabel{Name: "model", Value: model})
		}
		s.metrics.IncCounter("routing.invalid_ttft", labels...)
	}
}
