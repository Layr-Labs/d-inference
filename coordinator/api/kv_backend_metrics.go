package api

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
)

// Per-backend request instrumentation for the v0.8.0 paged-KV rollout
// (migration plan §16.1, Gate G5).
//
// With no canary fleet, per-backend segmentation is the only way to tell a
// paged regression from ordinary fleet noise. Three families are needed:
//
//   - error / 503 rate — d_inference.inference.request_outcome already carried
//     the OR-uptime class per request; it now also carries kv_backend, so the
//     numerator AND the denominator segment together (see openrouter_uptime.go).
//   - TTFT — the measured dispatch→first-content latency existed only as the
//     PERSISTED inference_routes.actual_ttft_ms column and the X-Timing
//     response header. Neither is groupable on a live dashboard, and the one
//     TTFT histogram in the coordinator (routing.cache_selection_ttft_ms) only
//     fires for cache-routing-participating requests. So the value is now also
//     emitted as d_inference.inference.ttft_ms.
//   - decode TPS — same story: outcome.ActualDecodeTPS was computed in
//     handleComplete and written only to Postgres. Now also
//     d_inference.inference.decode_tps.
//
// Neither histogram introduces a new MEASUREMENT: both take the value
// handleComplete already computed for the route-outcome row, at the same
// instant, so the metric and the persisted column cannot disagree.
const (
	// metricRequestTTFT is the delivered-content TTFT (dispatch → first content
	// chunk) in milliseconds — the same quantity persisted as actual_ttft_ms.
	// Tags: model, kv_backend.
	metricRequestTTFT = "inference.ttft_ms"
	// metricRequestDecodeTPS is the measured decode throughput (completion
	// tokens over the first-chunk → completion window) — the same quantity
	// persisted as actual_decode_tps. Tags: model, kv_backend.
	metricRequestDecodeTPS = "inference.decode_tps"
)

// emitRequestBackendLatency records the per-request TTFT and decode-throughput
// histograms, segmented by the serving slot's KV backend. Both values come from
// the completed route outcome; a non-finite or non-positive value means "not
// measurable for this request" and is skipped rather than recorded as a zero
// sample, which would drag a percentile toward the floor.
//
// Both guards run BEFORE the tags are built: ddHistogram checks s.dd only after
// its arguments exist, so an unconfigured Datadog (every test, every dev
// coordinator) would otherwise pay the tag construction on every completion.
func (s *Server) emitRequestBackendLatency(model string, attr dispatch.KVBackendAttribution, ttftMs, decodeTPS float64) {
	if s == nil || s.dd == nil {
		return
	}
	ttftUsable := usableMetricSample(ttftMs)
	decodeUsable := usableMetricSample(decodeTPS)
	if !ttftUsable && !decodeUsable {
		return
	}
	tags := attr.AppendTags(append(make([]string, 0, 3), "model:"+model))
	if ttftUsable {
		s.ddHistogram(metricRequestTTFT, ttftMs, tags)
	}
	if decodeUsable {
		s.ddHistogram(metricRequestDecodeTPS, decodeTPS, tags)
	}
}

func usableMetricSample(v float64) bool {
	return v > 0 && !math.IsNaN(v) && !math.IsInf(v, 0)
}
