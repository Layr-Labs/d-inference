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
	s.emitModelCacheCoverage("usage", usage, labels)
}

// Called only after V2 proof acceptance. ModelID has then been checked against
// both the issued request and the provider capability, before catalog labeling.
func (s *Server) emitModelCacheLookup(msg *protocol.PrefixCacheLookupV2Message, receipt registry.CacheReceiptResult) {
	if msg == nil || !receipt.Accepted {
		return
	}
	labels := []MetricLabel{{"model", s.cacheModelLabel(msg.ModelID)}, {"outcome", msg.Outcome}, {"tier", lowCardinalityCacheTier(msg.Tier)}}
	s.cacheModelCount("lookup", 1, labels...)
	// The denominator is the coordinator's exact plan, never a provider value.
	if receipt.PromptTokens > 0 {
		s.cacheModelCount("lookup_prompt_tokens", int64(receipt.PromptTokens), labels...)
		s.cacheModelCount("lookup_prefill_tokens_saved", int64(msg.ExpectedPrefillTokensSaved), labels...)
	}
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
func (s *Server) emitModelCacheSelection(pr *registry.PendingRequest, tags []string, usage protocol.UsageInfo, valid bool) {
	labels := s.cacheModelSelectionLabels(pr.Model, tags)
	s.cacheModelCount("selection", 1, labels...)
	if valid {
		s.emitModelCacheCoverage("selection", usage, labels)
	}
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

// Same-label numerator and denominator permit token-weighted coverage or
// hit-conditioned coverage without joining different request populations.
// Counts are only called from existing exactly-once terminal hooks. Invalid
// prompt counts do not contaminate denominators or create a division by zero.
func (s *Server) emitModelCacheCoverage(population string, usage protocol.UsageInfo, labels []MetricLabel) {
	if usage.PromptTokens <= 0 || usage.PromptTokens > 1_000_000 {
		return
	}
	s.cacheModelCount(population+"_prompt_tokens", int64(usage.PromptTokens), labels...)
	s.cacheModelCount(population+"_prefill_tokens_saved", int64(usage.PrefillTokensSaved), labels...)
	if s.metrics != nil {
		s.metrics.ObserveHistogram("cache_model_"+population+"_prefill_saved_percent", 100*float64(usage.PrefillTokensSaved)/float64(usage.PromptTokens), labels...)
	}
}

func (s *Server) emitModelCacheReceipt(model, tier, kind string, receipt registry.CacheReceiptResult) {
	outcome := "rejected"
	if receipt.Accepted {
		outcome = "accepted"
	}
	s.cacheModelCount("receipt", 1,
		MetricLabel{"model", s.cacheModelLabel(model)}, MetricLabel{"tier", lowCardinalityCacheTier(tier)},
		MetricLabel{"type", kind}, MetricLabel{"outcome", outcome}, MetricLabel{"reason", string(receipt.Reason)})
	if receipt.PromptMismatch != "" {
		s.cacheModelCount("prompt_mismatch", 1, MetricLabel{"model", s.cacheModelLabel(model)},
			MetricLabel{"tier", lowCardinalityCacheTier(tier)}, MetricLabel{"detail", string(receipt.PromptMismatch)})
	}
}
