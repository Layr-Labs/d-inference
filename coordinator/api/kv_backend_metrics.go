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

// kvBackendTagKey is the resolved-kind tag name. Deliberately the same key and
// the same vocabulary as BackendSlotCapacity.kv_backend on the heartbeat wire
// and `kv_backend` in the telemetry-event allowlist, so per-slot capacity,
// telemetry events and request metrics all group identically.
const kvBackendTagKey = "kv_backend:"

// kvBackendFallbackTagKey is the degrade-class tag name, mirroring
// BackendSlotCapacity.kv_backend_fallback_reason. It is what makes a
// `kv_backend:contiguous` sample interpretable: without it, an operator who
// chose contiguous and a paged slot that fell back are the same point on the
// dashboard. `.auto` resolves CONTIGUOUS in v0.8.0 and paged is opt-in per
// slot, so the population this separates today is a paged-configured fleet
// running under the DARKBLOOM_CBV2_PAGED_KV kill switch — which serves
// contiguous and, without this dimension, is indistinguishable from a fleet
// that asked for contiguous. `none` is a real value here, not a filler — see
// registry.KVBackendFallbackTag.
const kvBackendFallbackTagKey = "kv_backend_fallback:"

// kvBackendAttribution is the pair of KV-backend dimensions a request is tagged
// with. It exists as one value, resolved from one slot observation, because the
// two tags are only meaningful together: a `contiguous` paired with a stale
// `none` reads as a deliberate configuration and hides a regression.
//
// The zero value is the honest "no serving slot": both dimensions normalize to
// unknown, never to a real backend or to `none`.
type kvBackendAttribution struct {
	Backend  string
	Fallback string
}

// normalized fills both dimensions in, so the zero value (no serving slot)
// reads as unknown on both rather than as two empty tags.
func (a kvBackendAttribution) normalized() kvBackendAttribution {
	return kvBackendAttribution{
		Backend:  normalizeKVBackendTag(a.Backend),
		Fallback: normalizeKVBackendFallbackTag(a.Fallback),
	}
}

// tags renders the pair as metric tags. Both dimensions are always present so
// dashboards can group on either without losing rows.
func (a kvBackendAttribution) tags() []string {
	n := a.normalized()
	return []string{
		kvBackendTagKey + n.Backend,
		kvBackendFallbackTagKey + n.Fallback,
	}
}

// kvBackendAttribution resolves both metric dimensions for the SLOT (provider +
// concrete build id) that served a request. Provider granularity would be
// wrong: one box can hold up to maxModelSlots models and may serve paged for
// one and contiguous for another during a staged rollout.
//
// Returns the unknown pair when no slot observation exists — never a backend
// kind, and never `none`. Coercing an absent value to "contiguous"/"none" would
// make the rollout dashboard show a clean baseline composed entirely of
// pre-0.8.0 providers.
func (s *Server) kvBackendAttribution(providerID, model string) kvBackendAttribution {
	if s == nil || s.registry == nil {
		return kvBackendAttribution{
			Backend:  registry.KVBackendUnknown,
			Fallback: registry.KVFallbackUnknown,
		}
	}
	backend, fallback := s.registry.SlotKVBackendTags(providerID, model)
	return kvBackendAttribution{Backend: backend, Fallback: fallback}
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

// normalizeKVBackendFallbackTag is the same normalization for the degrade
// dimension. "" is UNKNOWN, never `none`: a call site with no serving slot has
// not established that nothing degraded.
func normalizeKVBackendFallbackTag(fallback string) string {
	if fallback == "" {
		return registry.KVFallbackUnknown
	}
	return fallback
}

// emitRequestBackendLatency records the per-request TTFT and decode-throughput
// histograms, segmented by the serving slot's KV backend. Both values come from
// the completed route outcome; a non-finite or non-positive value means "not
// measurable for this request" and is skipped rather than recorded as a zero
// sample, which would drag a percentile toward the floor.
func (s *Server) emitRequestBackendLatency(model string, attr kvBackendAttribution, ttftMs, decodeTPS float64) {
	tags := append([]string{"model:" + model}, attr.tags()...)
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

// noteServingSlot latches the KV-backend attribution of the slot this attempt
// was actually dispatched to. Called once per attempt, at the single point both
// the direct and the queue-drain paths converge on a dispatched request.
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
	d.servedKVBackend = d.s.kvBackendAttribution(pr.ProviderID, pr.Model)
}

// kvBackendAttribution is the KV-backend metric pair for this dispatch. It
// prefers the LIVE pending request, so a speculative backup that wins the race
// is attributed to the backup's slot rather than the primary's, and falls back
// to the latch once a failover has cleared it. A dispatch that never reached a
// slot tags as unknown on both dimensions.
func (d *dispatchState) kvBackendAttribution() kvBackendAttribution {
	if pr := d.pr; pr != nil && pr.ProviderID != "" {
		return d.s.kvBackendAttribution(pr.ProviderID, pr.Model)
	}
	return d.servedKVBackend.normalized()
}
