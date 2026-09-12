package api

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Coordinator-side latency-decomposition histograms (DogStatsD).
//
// The ParseMs..DispatchMs segments were computed per request
// (applyTimingDecomposition) and persisted on inference_routes, and surfaced
// to the consumer as the X-Timing response header — but neither is groupable
// on a live dashboard: the header is per-client, the column needs a Postgres
// query. inference.ttft_ms / inference.decode_tps (kv_backend_metrics.go)
// cover only the dispatch→first-content and decode windows, and only for
// provider-completed requests.
//
// This emits each segment as d_inference.inference.timing.<segment>_ms at the
// single store-submit funnel every terminal outcome flows through
// (updateInferenceRouteOutcomeWithModel), taking the value from the SAME
// outcome struct that is persisted — no new measurement, so the metric and
// the inference_routes column cannot disagree. Commit-time pre-fill writes
// (FinalStatus empty) are skipped so a successful request is counted once,
// at its terminal outcome; terminal outcomes that never measured a segment
// (zero) are skipped rather than recorded as zero samples, which would drag
// percentiles toward the floor.
//
// final_status is a tag (bounded vocabulary: success, partial_success,
// error, cancelled, timeout) so segment breakdowns for FAILED requests —
// which the X-Timing header never surfaces — are separable from successes.
const metricTimingSegmentPrefix = "inference.timing."

// emitTimingDecompositionMetric records the per-request latency-decomposition
// histograms. Guards run BEFORE any tag construction: an unconfigured
// Datadog (every test, every dev coordinator) must not pay per-completion
// allocations for metrics that go nowhere.
func (s *Server) emitTimingDecompositionMetric(model, finalStatus string, outcome *store.InferenceRouteOutcome) {
	if s == nil || s.dd == nil || outcome == nil || finalStatus == "" {
		return
	}
	segments := [...]struct {
		name  string
		value float64
	}{
		{"parse_ms", outcome.ParseMs},
		{"reserve_ms", outcome.ReserveMs},
		{"route_ms", outcome.RouteMs},
		{"encrypt_ms", outcome.EncryptMs},
		{"queue_wait_ms", outcome.QueueWaitMs},
		{"dispatch_ms", outcome.DispatchMs},
		{"total_duration_ms", outcome.TotalDurationMs},
	}
	tags := []string{"model:" + model, "final_status:" + finalStatus}
	for _, seg := range segments {
		if !usableMetricSample(seg.value) {
			continue
		}
		s.ddHistogram(metricTimingSegmentPrefix+seg.name, seg.value, tags)
	}
}
