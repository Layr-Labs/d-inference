package api

import (
	"math"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Model breakdowns are internal operational metrics. The public status and
// existing exact_cache metrics retain their aggregate-only contract. Never use
// a caller's alias, provider identity, request ID, receipt nonce or prompt hash.
func (s *Server) cacheModelLabel(model string) string {
	if s.registry != nil {
		if id, ok := s.registry.CatalogModelID(model); ok && id != "" && len(id) <= 200 && !strings.ContainsAny(id, ",|\n\r\x00") {
			return id
		}
	}
	return "unknown"
}

func (s *Server) cacheModelCount(name string, value int64, labels ...MetricLabel) {
	if s.metrics != nil {
		s.metrics.AddCounter("cache_model_"+name+"_total", value, labels...)
	}
	tags := make([]string, 0, len(labels))
	for _, label := range labels {
		tags = append(tags, label.Name+":"+label.Value)
	}
	s.ddCount("routing.cache_model."+name, value, tags)
}

// Sum/sample counters work with both Datadog HTTPS and DogStatsD. The admin
// histogram preserves milliseconds for percentiles; the estimate is not a
// measured counterfactual or a claim of successful end-to-end delivery.
func (s *Server) cacheModelTiming(name string, ms float64, labels ...MetricLabel) {
	if ms < 0 || math.IsNaN(ms) || math.IsInf(ms, 0) || ms >= float64(math.MaxInt64)/1000 {
		return
	}
	s.cacheModelCount(name+"_us", int64(math.Round(ms*1000)), labels...)
	s.cacheModelCount(name+"_samples", 1, labels...)
	if s.metrics != nil {
		s.metrics.ObserveHistogram("cache_model_"+name+"_ms", ms, labels...)
	}
}

// Same terminal-completion population as aggregate provider usage; includes
// parked completions, excludes unknown/duplicate/abandoned terminals. Invalid
// and absent usage are visible coverage gaps, never counted as cache misses.
func (s *Server) emitModelCacheUsage(pr *registry.PendingRequest, usage protocol.UsageInfo, valid, present bool) {
	if pr == nil {
		return
	}
	model := MetricLabel{"model", s.cacheModelLabel(pr.Model)}
	outcome, tier := "unreported", "none"
	if present && !valid {
		outcome = "invalid"
	} else if valid {
		outcome, tier = usage.CacheOutcome, lowCardinalityCacheTier(usage.CacheTier)
	}
	labels := []MetricLabel{model, {"outcome", outcome}, {"tier", tier}}
	s.cacheModelCount("usage", 1, labels...)
	if !valid {
		return
	}
	s.cacheModelCount("cached_tokens", int64(usage.CachedTokens), model, MetricLabel{"tier", tier})
	s.cacheModelCount("prefill_tokens_saved", int64(usage.PrefillTokensSaved), model, MetricLabel{"tier", tier})
	s.cacheModelTiming("provider_stage", usage.CacheStageMs, labels...)
}

// Called only after V2 proof acceptance. ModelID has then been checked against
// both the issued request and the provider capability, before catalog labeling.
func (s *Server) emitModelCacheLookup(msg *protocol.PrefixCacheLookupV2Message, receipt registry.CacheReceiptResult) {
	if msg == nil || !receipt.Accepted {
		return
	}
	s.cacheModelCount("lookup", 1,
		MetricLabel{"model", s.cacheModelLabel(msg.ModelID)},
		MetricLabel{"outcome", msg.Outcome},
		MetricLabel{"tier", lowCardinalityCacheTier(msg.Tier)})
}

func (s *Server) emitModelCacheDonation(msg *protocol.PrefixCacheReadyV2Message, receipt registry.CacheReceiptResult) {
	if msg == nil || !receipt.Accepted {
		return
	}
	s.cacheModelCount("donation", 1,
		MetricLabel{"model", s.cacheModelLabel(msg.ModelID)},
		MetricLabel{"tier", lowCardinalityCacheTier(msg.Tier)})
}

// Runs inside the existing exactly-once cache terminal claim. "result" is the
// provider's cache outcome, not consumer request success; an unreported error
// terminal remains distinguishable from a provider-reported hit or miss.
func (s *Server) emitModelCacheSelection(pr *registry.PendingRequest, tags []string) {
	labels := s.cacheModelSelectionLabels(pr.Model, tags)
	s.cacheModelCount("selection", 1, labels...)
	if ms := pr.CacheSelectionEstimatedTTFTSavedMs; ms > 0 {
		s.cacheModelTiming("estimated_ttft_saved", ms, labels...)
	}
}

func (s *Server) cacheModelSelectionLabels(model string, tags []string) []MetricLabel {
	labels := []MetricLabel{{"model", s.cacheModelLabel(model)}}
	for _, tag := range tags {
		name, value, _ := strings.Cut(tag, ":")
		labels = append(labels, MetricLabel{name, value})
	}
	return labels
}
