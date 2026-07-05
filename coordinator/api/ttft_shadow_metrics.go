package api

import "github.com/eigeninference/d-inference/coordinator/registry"

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

// emitTTFTShadowMetrics records the Phase-0 shadow admission/spread decision for
// a selected provider. decision.ShadowEvaluated is true only when
// EIGENINFERENCE_TTFT_ADMISSION_MODE != off and a provider was selected, so this
// is a no-op in the default (off) configuration.
//
//   - routing.ttft_admission{decision:would_shed|would_serve} — would the
//     occupancy-aware estimate at the ~10s base have shed the chosen provider.
//   - routing.ttft_spread{would_redirect_to_idle:true|false} — was an
//     instantly-usable loaded-idle peer for the same model available to spread to.
func (s *Server) emitTTFTShadowMetrics(model string, decision registry.RoutingDecision) {
	if s == nil || !decision.ShadowEvaluated {
		return
	}
	shedTag := "would_serve"
	if decision.ShadowWouldShed {
		shedTag = "would_shed"
	}
	redirectTag := "false"
	if decision.ShadowIdleAlternativeExists {
		redirectTag = "true"
	}

	s.ddIncr("routing.ttft_admission", []string{"model:" + model, "decision:" + shedTag, "mode:" + decision.ShadowMode})
	s.ddIncr("routing.ttft_spread", []string{"model:" + model, "would_redirect_to_idle:" + redirectTag, "mode:" + decision.ShadowMode})
	if s.metrics != nil {
		s.metrics.IncCounter("routing.ttft_admission",
			MetricLabel{Name: "model", Value: model},
			MetricLabel{Name: "decision", Value: shedTag},
			MetricLabel{Name: "mode", Value: decision.ShadowMode},
		)
		s.metrics.IncCounter("routing.ttft_spread",
			MetricLabel{Name: "model", Value: model},
			MetricLabel{Name: "would_redirect_to_idle", Value: redirectTag},
			MetricLabel{Name: "mode", Value: decision.ShadowMode},
		)
	}
	if s.logger != nil {
		s.logger.Debug("ttft shadow admission",
			"model", model,
			"mode", decision.ShadowMode,
			"would_shed", decision.ShadowWouldShed,
			"would_redirect_to_idle", decision.ShadowIdleAlternativeExists,
			"estimate_ms", decision.ShadowEstimateMs,
			"deadline_ms", decision.ShadowDeadlineMs,
			"occupancy", decision.ShadowOccupancy,
			"provider_id", decision.ProviderID,
		)
	}
}
