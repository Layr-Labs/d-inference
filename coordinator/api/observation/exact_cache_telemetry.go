package observation

import (
	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"math"
	"time"
)

// All exact-cache telemetry is intentionally low-cardinality. It never tags a
// model, provider, account, request, scope, hash, route key, or prompt-derived
// value.
func (s *Owner) EmitExactCachePlan(result registry.CachePlanResult) {
	outcome := string(result.Outcome)
	if outcome == "" {
		outcome = string(registry.CachePlanIneligible)
	}
	if s.Metrics() != nil {
		s.Metrics().IncCounter("exact_cache_plan_total", metriclabels.MetricLabel{Name: "outcome", Value: outcome})
	}
	s.Incr("exact_cache.plan", []string{"outcome:" + outcome})
	if !result.SidecarCalled {
		return
	}
	latencyMs := float64(result.PlanLatency) / float64(time.Millisecond)
	if latencyMs < 0 {
		return
	}
	if s.Metrics() != nil {
		s.Metrics().ObserveHistogram("exact_cache_plan_latency_ms", latencyMs,
			metriclabels.MetricLabel{Name: "outcome", Value: outcome})
	}
	s.Histogram("exact_cache.plan_latency_ms", latencyMs, []string{"outcome:" + outcome})
}

func (s *Owner) EmitExactCacheSSDLookup(protocolVersion, outcome string, stageMs float64) {
	tags := []string{"protocol:" + protocolVersion, "outcome:" + outcome, "tier:ssd"}
	if s.Metrics() != nil {
		s.Metrics().IncCounter("exact_cache_ssd_lookup_total",
			metriclabels.MetricLabel{Name: "protocol", Value: protocolVersion},
			metriclabels.MetricLabel{Name: "outcome", Value: outcome})
		s.Metrics().ObserveHistogram("exact_cache_ssd_stage_ms", stageMs,
			metriclabels.MetricLabel{Name: "event", Value: "lookup"}, metriclabels.MetricLabel{Name: "outcome", Value: outcome})
	}
	s.Incr("exact_cache.ssd_lookup", tags)
	s.Histogram("exact_cache.ssd_stage_ms", stageMs, append(tags, "event:lookup"))
}

func (s *Owner) EmitExactCacheSSDDonation(protocolVersion string, stageMs float64, donatedTokens int) {
	tags := []string{"protocol:" + protocolVersion, "tier:ssd"}
	if s.Metrics() != nil {
		s.Metrics().IncCounter("exact_cache_ssd_donation_total",
			metriclabels.MetricLabel{Name: "protocol", Value: protocolVersion})
		s.Metrics().AddCounter("exact_cache_ssd_donated_tokens_total", int64(donatedTokens),
			metriclabels.MetricLabel{Name: "protocol", Value: protocolVersion})
		s.Metrics().ObserveHistogram("exact_cache_ssd_stage_ms", stageMs,
			metriclabels.MetricLabel{Name: "event", Value: "donation"})
	}
	s.Incr("exact_cache.ssd_donation", tags)
	s.Count("exact_cache.ssd_donated_tokens", int64(donatedTokens), tags)
	s.Histogram("exact_cache.ssd_stage_ms", stageMs, append(tags, "event:donation"))
}

func (s *Owner) EmitExactCacheUsage(outcome, tier string, cachedTokens, prefillTokensSaved int, stageMs float64) {
	tags := []string{"outcome:" + outcome, "tier:" + tier}
	if s.Metrics() != nil {
		s.Metrics().IncCounter("exact_cache_usage_total",
			metriclabels.MetricLabel{Name: "outcome", Value: outcome}, metriclabels.MetricLabel{Name: "tier", Value: tier})
		s.Metrics().AddCounter("exact_cache_cached_tokens_total", int64(cachedTokens),
			metriclabels.MetricLabel{Name: "tier", Value: tier})
		s.Metrics().AddCounter("exact_cache_prefill_tokens_saved_total", int64(prefillTokensSaved),
			metriclabels.MetricLabel{Name: "tier", Value: tier})
		s.Metrics().ObserveHistogram("exact_cache_provider_stage_ms", stageMs,
			metriclabels.MetricLabel{Name: "outcome", Value: outcome}, metriclabels.MetricLabel{Name: "tier", Value: tier})
	}
	s.Incr("exact_cache.usage", tags)
	s.Count("exact_cache.cached_tokens", int64(cachedTokens), tags)
	s.Count("exact_cache.prefill_tokens_saved", int64(prefillTokensSaved), tags)
	s.Histogram("exact_cache.provider_stage_ms", stageMs, tags)
}

func (s *Owner) EmitExactCacheEstimatedTTFTSaved(pr *registry.PendingRequest, tags []string) {
	if pr == nil || pr.CacheSelectionEstimatedTTFTSavedMs <= 0 ||
		math.IsNaN(pr.CacheSelectionEstimatedTTFTSavedMs) ||
		math.IsInf(pr.CacheSelectionEstimatedTTFTSavedMs, 0) {
		return
	}
	value := pr.CacheSelectionEstimatedTTFTSavedMs
	if s.Metrics() != nil {
		s.Metrics().ObserveHistogram("exact_cache_estimated_ttft_saved_ms", value,
			metriclabels.MetricLabel{Name: "tier", Value: metriclabels.LowCardinalityCacheTier(pr.CacheSelectionTier)})
	}
	s.Histogram("exact_cache.estimated_ttft_saved_ms", value, tags)
}

// Count acceptance separately from provider-reported usage. Rejected evidence
// never becomes a cache hit merely because the provider reported saved tokens.
func (s *Owner) EmitCacheReceiptResult(kind string, result registry.CacheReceiptResult) {
	outcome := "rejected"
	if result.Accepted {
		outcome = "accepted"
	}
	if s.Metrics() != nil {
		s.Metrics().IncCounter("exact_cache_receipt_total", metriclabels.MetricLabel{Name: "type", Value: kind}, metriclabels.MetricLabel{Name: "outcome", Value: outcome}, metriclabels.MetricLabel{Name: "reason", Value: string(result.Reason)})
	}
	s.Incr("exact_cache.receipt", []string{"type:" + kind, "outcome:" + outcome, "reason:" + string(result.Reason)})
}
