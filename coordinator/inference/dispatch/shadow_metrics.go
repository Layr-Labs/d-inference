package dispatch

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// emitTTFTShadowMetrics records the Phase-0 shadow admission/spread decision for
// a selected provider. decision.ShadowEvaluated is true only when
// EIGENINFERENCE_TTFT_ADMISSION_MODE != off and a provider was selected, so this
// is a no-op in the default (off) configuration.
//
//   - routing.ttft_admission{decision:would_shed|would_serve} — would the
//     occupancy-aware estimate at the ~10s base have shed the chosen provider.
//   - routing.ttft_spread{would_redirect_to_idle:true|false} — was an
//     instantly-usable loaded-idle peer for the same model available to spread to.
func (s *Controller) emitTTFTShadowMetrics(model string, decision registry.RoutingDecision) {
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

	s.deps.Counters.Incr("routing.ttft_admission", []string{"model:" + model, "decision:" + shedTag, "mode:" + decision.ShadowMode})
	s.deps.Counters.Incr("routing.ttft_spread", []string{"model:" + model, "would_redirect_to_idle:" + redirectTag, "mode:" + decision.ShadowMode})
	if s.deps.Metrics() != nil {
		s.deps.Metrics().IncCounter("routing.ttft_admission",
			metrics.Label{Name: "model", Value: model},
			metrics.Label{Name: "decision", Value: shedTag},
			metrics.Label{Name: "mode", Value: decision.ShadowMode},
		)
		s.deps.Metrics().IncCounter("routing.ttft_spread",
			metrics.Label{Name: "model", Value: model},
			metrics.Label{Name: "would_redirect_to_idle", Value: redirectTag},
			metrics.Label{Name: "mode", Value: decision.ShadowMode},
		)
	}
	if s.deps.Logger() != nil {
		s.deps.Logger().Debug("ttft shadow admission",
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
