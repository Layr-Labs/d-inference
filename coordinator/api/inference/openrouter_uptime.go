package inference

import infermetrics "github.com/eigeninference/d-inference/coordinator/internal/inference/metrics"

func (d *dispatchState) recordDispatchedRequestOutcome(attr kvBackendAttribution, class string) {
	if d == nil || !infermetrics.IsOpenRouterScoredDispatchEndpoint(d.consumerEndpoint) {
		return
	}
	d.s.recordRequestOutcome(d.model, attr, class)
}

// recordRequestOutcome emits the per-request OR-uptime outcome counter. model is
// normalized to "unknown" when empty (e.g. a rejection before model resolution)
// so the tag is always present for dashboard grouping. No-op when Datadog is
// unconfigured (ddIncr guards nil).
//
// attr is the KV-backend attribution of the SLOT that served (or last
// attempted) the request — the v0.8.0 paged-rollout dimensions (Gate G5).
// Because the class tag already splits success from every failure kind, adding
// them here segments the error rate's numerator AND denominator at once, which
// is what makes "is paged 503ing more than contiguous" answerable — and the
// fallback dimension is what keeps "contiguous" from silently pooling operator
// choice together with paged slots that degraded. The zero value normalizes to
// unknown on both: a request that never reached a slot (pre-dispatch rejection)
// is genuinely unattributable, and must never be booked to a real backend or
// counted as a slot that did not degrade.
func (s *Owner) recordRequestOutcome(model string, attr kvBackendAttribution, class string) {
	if s != nil {
		s.NewMetrics().BackendOutcome(model, attr, class)
	}
}
