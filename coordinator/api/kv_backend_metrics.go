package api

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Per-backend request instrumentation for the v0.8.0 paged-KV rollout
// (migration plan §16.1, Gate G5).
//
// With no canary fleet, per-backend segmentation is the only way to tell a
// paged regression from ordinary fleet noise. Three families are needed:
//
//   - error / 503 rate — d_inference.inference.request_outcome already carried
//     the OR-uptime class per request; it now also carries kv_backend, so the
//     numerator AND the denominator segment together (see or_uptime.go).
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

// kvBackendTagKey is the tag name. Deliberately the same key and the same
// vocabulary as BackendSlotCapacity.kv_backend on the heartbeat wire and
// `kv_backend` in the telemetry-event allowlist, so per-slot capacity,
// telemetry events and request metrics all group identically.
const kvBackendTagKey = "kv_backend:"

// kvBackendTag resolves the metric tag for the SLOT (provider + concrete build
// id) that served a request. Provider granularity would be wrong: one box can
// hold up to maxModelSlots models and may serve paged for one and contiguous
// for another during a staged rollout.
//
// Returns registry.KVBackendUnknown when no slot observation exists — never a
// backend kind. Coercing an absent value to "contiguous" would make the rollout
// dashboard show a clean baseline composed entirely of pre-0.8.0 providers.
func (s *Server) kvBackendTag(providerID, model string) string {
	if s == nil || s.registry == nil {
		return registry.KVBackendUnknown
	}
	return s.registry.SlotKVBackendTag(providerID, model)
}

// normalizeKVBackendTag maps an empty tag to the explicit unknown value so the
// dimension is always present for dashboard grouping (the same normalization
// recordRequestOutcome applies to model, and emitClientGone to chip_family).
// "" reaches here only from a call site with no serving slot at all.
func normalizeKVBackendTag(kvBackend string) string {
	if kvBackend == "" {
		return registry.KVBackendUnknown
	}
	return kvBackend
}

// emitRequestBackendLatency records the per-request TTFT and decode-throughput
// histograms, segmented by the serving slot's KV backend. Both values come from
// the completed route outcome; a non-finite or non-positive value means "not
// measurable for this request" and is skipped rather than recorded as a zero
// sample, which would drag a percentile toward the floor.
func (s *Server) emitRequestBackendLatency(model, kvBackend string, ttftMs, decodeTPS float64) {
	tags := []string{"model:" + model, kvBackendTagKey + normalizeKVBackendTag(kvBackend)}
	if usableMetricSample(ttftMs) {
		s.ddHistogram(metricRequestTTFT, ttftMs, tags)
	}
	if usableMetricSample(decodeTPS) {
		s.ddHistogram(metricRequestDecodeTPS, decodeTPS, tags)
	}
}

func usableMetricSample(v float64) bool {
	return v > 0 && !math.IsNaN(v) && !math.IsInf(v, 0)
}

// noteServingSlot latches the KV backend of the slot this attempt was actually
// dispatched to. Called once per attempt, at the single point both the direct
// and the queue-drain paths converge on a dispatched request.
//
// The latch exists because every failover path clears d.provider/d.pr before
// the exhaustion ladder runs, and the ladder is where a dispatched-but-failed
// request emits its OR-uptime outcome. Without it the 5xx/timeout population —
// the half of Gate G5 that catches a paged regression — would all land in
// kv_backend:unknown.
func (d *dispatchState) noteServingSlot() {
	pr := d.pr
	if pr == nil || pr.ProviderID == "" {
		return
	}
	d.servedKVBackend = d.s.kvBackendTag(pr.ProviderID, pr.Model)
}

// kvBackendTag is the KV-backend metric tag for this dispatch. It prefers the
// LIVE pending request, so a speculative backup that wins the race is attributed
// to the backup's slot rather than the primary's, and falls back to the latch
// once a failover has cleared it. "" (never reached a slot) tags as unknown.
func (d *dispatchState) kvBackendTag() string {
	if pr := d.pr; pr != nil && pr.ProviderID != "" {
		return d.s.kvBackendTag(pr.ProviderID, pr.Model)
	}
	return normalizeKVBackendTag(d.servedKVBackend)
}
