package api

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// All exact-cache telemetry is intentionally low-cardinality. It never tags a
// model, provider, account, request, scope, hash, route key, or prompt-derived
// value.
func (s *Server) emitExactCachePlan(result registry.CachePlanResult) {
	outcome := string(result.Outcome)
	if outcome == "" {
		outcome = string(registry.CachePlanIneligible)
	}
	if s.metrics != nil {
		s.metrics.IncCounter("exact_cache_plan_total", MetricLabel{"outcome", outcome})
	}
	s.ddIncr("exact_cache.plan", []string{"outcome:" + outcome})
	if !result.SidecarCalled {
		return
	}
	latencyMs := float64(result.PlanLatency) / float64(time.Millisecond)
	if latencyMs < 0 {
		return
	}
	if s.metrics != nil {
		s.metrics.ObserveHistogram("exact_cache_plan_latency_ms", latencyMs,
			MetricLabel{"outcome", outcome})
	}
	s.ddHistogram("exact_cache.plan_latency_ms", latencyMs, []string{"outcome:" + outcome})
}

func (s *Server) emitExactCacheSSDLookup(protocolVersion, outcome string, stageMs float64) {
	tags := []string{"protocol:" + protocolVersion, "outcome:" + outcome, "tier:ssd"}
	if s.metrics != nil {
		s.metrics.IncCounter("exact_cache_ssd_lookup_total",
			MetricLabel{"protocol", protocolVersion},
			MetricLabel{"outcome", outcome})
		s.metrics.ObserveHistogram("exact_cache_ssd_stage_ms", stageMs,
			MetricLabel{"event", "lookup"}, MetricLabel{"outcome", outcome})
	}
	s.ddIncr("exact_cache.ssd_lookup", tags)
	s.ddHistogram("exact_cache.ssd_stage_ms", stageMs, append(tags, "event:lookup"))
}

func (s *Server) emitExactCacheSSDDonation(protocolVersion string, stageMs float64, donatedTokens int) {
	tags := []string{"protocol:" + protocolVersion, "tier:ssd"}
	if s.metrics != nil {
		s.metrics.IncCounter("exact_cache_ssd_donation_total",
			MetricLabel{"protocol", protocolVersion})
		s.metrics.AddCounter("exact_cache_ssd_donated_tokens_total", int64(donatedTokens),
			MetricLabel{"protocol", protocolVersion})
		s.metrics.ObserveHistogram("exact_cache_ssd_stage_ms", stageMs,
			MetricLabel{"event", "donation"})
	}
	s.ddIncr("exact_cache.ssd_donation", tags)
	s.ddCount("exact_cache.ssd_donated_tokens", int64(donatedTokens), tags)
	s.ddHistogram("exact_cache.ssd_stage_ms", stageMs, append(tags, "event:donation"))
}

func (s *Server) emitExactCacheUsage(outcome, tier string, cachedTokens, prefillTokensSaved int, stageMs float64) {
	tags := []string{"outcome:" + outcome, "tier:" + tier}
	if s.metrics != nil {
		s.metrics.IncCounter("exact_cache_usage_total",
			MetricLabel{"outcome", outcome}, MetricLabel{"tier", tier})
		s.metrics.AddCounter("exact_cache_cached_tokens_total", int64(cachedTokens),
			MetricLabel{"tier", tier})
		s.metrics.AddCounter("exact_cache_prefill_tokens_saved_total", int64(prefillTokensSaved),
			MetricLabel{"tier", tier})
		s.metrics.ObserveHistogram("exact_cache_provider_stage_ms", stageMs,
			MetricLabel{"outcome", outcome}, MetricLabel{"tier", tier})
	}
	s.ddIncr("exact_cache.usage", tags)
	s.ddCount("exact_cache.cached_tokens", int64(cachedTokens), tags)
	s.ddCount("exact_cache.prefill_tokens_saved", int64(prefillTokensSaved), tags)
	s.ddHistogram("exact_cache.provider_stage_ms", stageMs, tags)
}

func (s *Server) emitExactCacheEstimatedTTFTSaved(pr *registry.PendingRequest, tags []string) {
	if pr == nil || pr.CacheSelectionEstimatedTTFTSavedMs <= 0 ||
		math.IsNaN(pr.CacheSelectionEstimatedTTFTSavedMs) ||
		math.IsInf(pr.CacheSelectionEstimatedTTFTSavedMs, 0) {
		return
	}
	value := pr.CacheSelectionEstimatedTTFTSavedMs
	if s.metrics != nil {
		s.metrics.ObserveHistogram("exact_cache_estimated_ttft_saved_ms", value,
			MetricLabel{"tier", lowCardinalityCacheTier(pr.CacheSelectionTier)})
	}
	s.ddHistogram("exact_cache.estimated_ttft_saved_ms", value, tags)
}
