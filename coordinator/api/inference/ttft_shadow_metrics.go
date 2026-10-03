package inference

import (
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// emitInvalidTTFT fires when applyPendingRouteTelemetry clamped a negative raw
// time-to-first-token to 0. It is the loud guard against any regression of the
// retried-request shared-Timing bug (FirstContentAt of an early attempt minus a
// later attempt's overwritten DispatchedAt), which produced -ms rows down to
// -378s. Emitted from the single store-submit funnel so it covers every path.
func (s *Owner) emitInvalidTTFT(model, reason string) {
	if s == nil {
		return
	}
	tags := []string{"reason:" + reason}
	if model != "" {
		tags = append(tags, "model:"+model)
	}
	s.observation.Incr("routing.invalid_ttft", tags)
	if s.observation.Metrics() != nil {
		labels := []observation.MetricLabel{{Name: "reason", Value: reason}}
		if model != "" {
			labels = append(labels, observation.MetricLabel{Name: "model", Value: model})
		}
		s.observation.Metrics().IncCounter("routing.invalid_ttft", labels...)
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
func (s *Owner) emitTTFTShadowMetrics(model string, decision registry.RoutingDecision) {
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

	s.observation.Incr("routing.ttft_admission", []string{"model:" + model, "decision:" + shedTag, "mode:" + decision.ShadowMode})
	s.observation.Incr("routing.ttft_spread", []string{"model:" + model, "would_redirect_to_idle:" + redirectTag, "mode:" + decision.ShadowMode})
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("routing.ttft_admission",
			observation.MetricLabel{Name: "model", Value: model},
			observation.MetricLabel{Name: "decision", Value: shedTag},
			observation.MetricLabel{Name: "mode", Value: decision.ShadowMode},
		)
		s.observation.Metrics().IncCounter("routing.ttft_spread",
			observation.MetricLabel{Name: "model", Value: model},
			observation.MetricLabel{Name: "would_redirect_to_idle", Value: redirectTag},
			observation.MetricLabel{Name: "mode", Value: decision.ShadowMode},
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
