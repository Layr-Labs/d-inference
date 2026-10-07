package observation

import (
	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Same terminal-completion population as aggregate provider usage; includes
// parked completions, excludes unknown/duplicate/abandoned terminals. Invalid
// and absent usage are visible coverage gaps, never counted as cache misses.
func (s *Owner) EmitModelCacheUsage(pr *registry.PendingRequest, usage protocol.UsageInfo, valid, present bool) {
	if pr == nil {
		return
	}
	model := metriclabels.MetricLabel{Name: "model", Value: s.cacheModelLabel(pr.Model)}
	outcome, tier := "unreported", "none"
	if present && !valid {
		outcome = "invalid"
	} else if valid {
		outcome, tier = usage.CacheOutcome, metriclabels.LowCardinalityCacheTier(usage.CacheTier)
	}
	labels := []metriclabels.MetricLabel{model, {Name: "outcome", Value: outcome}, {Name: "tier", Value: tier}}
	s.cacheModelCount("usage", 1, labels...)
	if !valid {
		return
	}
	s.cacheModelCount("cached_tokens", int64(usage.CachedTokens), model, metriclabels.MetricLabel{Name: "tier", Value: tier})
	s.cacheModelCount("prefill_tokens_saved", int64(usage.PrefillTokensSaved), model, metriclabels.MetricLabel{Name: "tier", Value: tier})
	s.cacheModelTiming("provider_stage", usage.CacheStageMs, labels...)
	s.emitModelCacheCoverage("usage", usage, labels)
}

// Called only after V2 proof acceptance. ModelID has then been checked against
// both the issued request and the provider capability, before catalog labeling.
func (s *Owner) EmitModelCacheLookup(msg *protocol.PrefixCacheLookupV2Message, receipt registry.CacheReceiptResult) {
	if msg == nil || !receipt.Accepted {
		return
	}
	labels := []metriclabels.MetricLabel{{Name: "model", Value: s.cacheModelLabel(msg.ModelID)}, {Name: "outcome", Value: msg.Outcome}, {Name: "tier", Value: metriclabels.LowCardinalityCacheTier(msg.Tier)}}
	s.cacheModelCount("lookup", 1, labels...)
	// The denominator is the coordinator's exact plan, never a provider value.
	if receipt.PromptTokens > 0 {
		s.cacheModelCount("lookup_prompt_tokens", int64(receipt.PromptTokens), labels...)
		s.cacheModelCount("lookup_prefill_tokens_saved", int64(msg.ExpectedPrefillTokensSaved), labels...)
	}
}

func (s *Owner) EmitModelCacheDonation(msg *protocol.PrefixCacheReadyV2Message, receipt registry.CacheReceiptResult) {
	if msg == nil || !receipt.Accepted {
		return
	}
	s.cacheModelCount("donation", 1,
		metriclabels.MetricLabel{Name: "model", Value: s.cacheModelLabel(msg.ModelID)},
		metriclabels.MetricLabel{Name: "tier", Value: metriclabels.LowCardinalityCacheTier(msg.Tier)})
}

// Runs inside the existing exactly-once cache terminal claim. "result" is the
// provider's cache outcome, not consumer request success; an unreported error
// terminal remains distinguishable from a provider-reported hit or miss.
func (s *Owner) EmitModelCacheSelection(pr *registry.PendingRequest, tags []string, usage protocol.UsageInfo, valid bool) {
	labels := s.cacheModelSelectionLabels(pr.Model, tags)
	s.cacheModelCount("selection", 1, labels...)
	s.EmitCacheOpportunity(pr)
	if valid {
		s.emitModelCacheCoverage("selection", usage, labels)
	}
	if ms := pr.CacheSelectionEstimatedTTFTSavedMs; ms > 0 {
		s.cacheModelTiming("estimated_ttft_saved", ms, labels...)
	}
}

// Same-label numerator and denominator permit token-weighted coverage or
// hit-conditioned coverage without joining different request populations.
// Counts are only called from existing exactly-once terminal hooks. Invalid
// prompt counts do not contaminate denominators or create a division by zero.
func (s *Owner) emitModelCacheCoverage(population string, usage protocol.UsageInfo, labels []metriclabels.MetricLabel) {
	if usage.PromptTokens <= 0 || usage.PromptTokens > 1_000_000 {
		return
	}
	s.cacheModelCount(population+"_prompt_tokens", int64(usage.PromptTokens), labels...)
	s.cacheModelCount(population+"_prefill_tokens_saved", int64(usage.PrefillTokensSaved), labels...)
	if s.Metrics() != nil {
		s.Metrics().ObserveHistogram("cache_model_"+population+"_prefill_saved_percent", 100*float64(usage.PrefillTokensSaved)/float64(usage.PromptTokens), labels...)
	}
}

func (s *Owner) EmitModelCacheReceipt(model, tier, kind string, receipt registry.CacheReceiptResult) {
	outcome := "rejected"
	if receipt.Accepted {
		outcome = "accepted"
	}
	s.cacheModelCount("receipt", 1,
		metriclabels.MetricLabel{Name: "model", Value: s.cacheModelLabel(model)}, metriclabels.MetricLabel{Name: "tier", Value: metriclabels.LowCardinalityCacheTier(tier)},
		metriclabels.MetricLabel{Name: "type", Value: kind}, metriclabels.MetricLabel{Name: "outcome", Value: outcome}, metriclabels.MetricLabel{Name: "reason", Value: string(receipt.Reason)})
	if receipt.PromptMismatch != "" {
		s.cacheModelCount("prompt_mismatch", 1, metriclabels.MetricLabel{Name: "model", Value: s.cacheModelLabel(model)},
			metriclabels.MetricLabel{Name: "tier", Value: metriclabels.LowCardinalityCacheTier(tier)}, metriclabels.MetricLabel{Name: "detail", Value: string(receipt.PromptMismatch)})
	}
}
