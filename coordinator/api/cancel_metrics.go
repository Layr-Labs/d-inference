package api

import "github.com/eigeninference/d-inference/coordinator/store"

// Datadog metrics for structured cancellation telemetry (DAR-346).
//
// Emitted from the single outcome-write chokepoint (updateInferenceRouteOutcome-
// WithModel) so the counters can never drift from what is persisted on
// inference_routes. All go through the DogStatsD wrappers (ddIncr/ddCount), which
// no-op when Datadog is unconfigured (tests). The "d_inference." namespace is
// prepended by datadog.Client. Tags are low-cardinality (phase/source/status are
// closed enums; model is already used fleet-wide).
//
// Speculative losers are emitted with phase:speculative_loser / source:
// speculative_loser so dashboards can EXCLUDE them from external client-cancel
// rates (DAR-346 acceptance criterion) without losing the data.
//
// Note: idle gap is a BUCKETED COUNTER, not a histogram — histograms are
// DogStatsD-only and produce nothing on the EigenCloud TEE (no DD agent), so a
// histogram here would be silently empty in prod. Buckets ride the HTTP /series
// counter path that works in the TEE.
const (
	metricCancel                  = "inference.cancel"
	metricCancelDeliveredTokens   = "inference.cancel.delivered_tokens"
	metricCancelPartialSettlement = "inference.cancel.partial_settlement"
	metricStreamIdleGap           = "inference.stream.idle_gap"
)

// idleGapBucket maps a measured no-progress gap (ms) to a coarse, low-cardinality
// bucket label.
func idleGapBucket(ms float64) string {
	switch {
	case ms < 1000:
		return "lt_1s"
	case ms < 5000:
		return "1_5s"
	case ms < 15000:
		return "5_15s"
	case ms < 30000:
		return "15_30s"
	default:
		return "gte_30s"
	}
}

// emitCancelMetrics emits the cancellation counters for a persisted cancellation
// outcome. It is a no-op for non-cancellation outcomes (empty CancelPhase) and
// for the interim commit/latency-only updates that don't set it.
func (s *Server) emitCancelMetrics(model string, outcome *store.InferenceRouteOutcome) {
	if s == nil || outcome == nil || outcome.CancelPhase == "" {
		return
	}
	source := outcome.CancelSource
	if source == "" {
		source = cancelSourceUnknown
	}
	modelTag := "model:" + model
	s.ddIncr(metricCancel, []string{"phase:" + outcome.CancelPhase, "source:" + source, modelTag})
	if outcome.PartialSettlementStatus != "" {
		s.ddIncr(metricCancelPartialSettlement, []string{"status:" + outcome.PartialSettlementStatus, modelTag})
	}
	if outcome.EstimatedDeliveredTokens > 0 {
		s.ddCount(metricCancelDeliveredTokens, int64(outcome.EstimatedDeliveredTokens), []string{modelTag})
	}
	if outcome.MaxIdleGapMs > 0 {
		s.ddIncr(metricStreamIdleGap, []string{"bucket:" + idleGapBucket(outcome.MaxIdleGapMs), modelTag})
	}
}
