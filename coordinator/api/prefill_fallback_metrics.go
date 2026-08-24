package api

// Prefill-fallback shadow telemetry (DogStatsD + the in-process /v1/admin/metrics
// registry). Pure observability — emitted only when
// EIGENINFERENCE_PREFILL_FALLBACK_MODE=shadow, where live routing is unchanged
// (still on the legacy ~280 tok/s fallback) and we measure how many of today's
// long-prompt ttft_429s the recalibrated fallback (~6500 tok/s) WOULD recover
// before flipping enforce.
//
//   - routing.prefill_fallback{decision:would_admit} — the live (legacy) estimate
//     sheds this request on TTFT, but the recalibrated estimate clears the same
//     deadline: a 429 the enforce flip would convert to a served request.
//   - routing.prefill_fallback{decision:would_shed} — even the recalibrated
//     estimate is over the deadline (genuinely too slow; enforce would not help).
//
// The caller invokes this only for requests the live estimate already flagged
// ttft_too_slow, so the would_admit / would_shed split is exactly the projected
// recovery vs. residual.
func (s *Server) emitPrefillFallbackShadow(model string, recalibratedAdmits bool) {
	if s == nil {
		return
	}
	decision := "would_shed"
	if recalibratedAdmits {
		decision = "would_admit"
	}
	s.ddIncr("routing.prefill_fallback", []string{"model:" + model, "decision:" + decision, "mode:shadow"})
	if s.metrics != nil {
		s.metrics.IncCounter("routing.prefill_fallback",
			MetricLabel{Name: "model", Value: model},
			MetricLabel{Name: "decision", Value: decision},
			MetricLabel{Name: "mode", Value: "shadow"},
		)
	}
	if s.logger != nil {
		s.logger.Debug("prefill fallback shadow",
			"model", model,
			"decision", decision,
		)
	}
}
