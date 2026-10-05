package cacheusage

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func LowCardinalityTier(tier string) string {
	return observation.LowCardinalityCacheTier(tier)
}

func Valid(usage protocol.UsageInfo) bool {
	switch usage.CacheOutcome {
	case "":
		return false
	case "hit", "miss_absent", "miss_corrupt", "skipped_capacity", "skipped_cost", "skipped_policy":
	default:
		return false
	}
	if usage.CacheTier != "" && usage.CacheTier != "memory" && usage.CacheTier != "ssd" {
		return false
	}
	const maxCacheUsageTokens = 1_000_000
	if usage.CachedTokens < 0 || usage.CachedTokens > maxCacheUsageTokens || usage.CachedTokens > usage.PromptTokens ||
		usage.PrefillTokensSaved < 0 || usage.PrefillTokensSaved > usage.CachedTokens ||
		usage.CacheStageMs < 0 || usage.CacheStageMs > 10*60*1000 || math.IsNaN(usage.CacheStageMs) || math.IsInf(usage.CacheStageMs, 0) {
		return false
	}
	if usage.CacheOutcome == "hit" {
		return usage.CacheTier != "" && usage.CachedTokens > 0 && usage.PrefillTokensSaved > 0
	}
	return usage.CachedTokens == 0 && usage.PrefillTokensSaved == 0
}

// billableUsage maps a provider's terminal usage onto the billing breakdown.
// The usage must already have passed validCacheUsage (clearCacheUsage zeroes a
// malformed report), so what is billed at the cache-read rate is exactly the
// prompt_tokens_details.cached_tokens the consumer sees.
func Billable(usage protocol.UsageInfo) payments.Usage {
	return payments.Usage{
		PromptTokens:     usage.PromptTokens,
		CachedTokens:     usage.CachedTokens,
		CompletionTokens: usage.CompletionTokens,
	}
}

func Clear(usage *protocol.UsageInfo) {
	if usage == nil {
		return
	}
	usage.CacheOutcome = ""
	usage.CacheTier = ""
	usage.CachedTokens = 0
	usage.PrefillTokensSaved = 0
	usage.CacheStageMs = 0
}

func Has(usage protocol.UsageInfo) bool {
	return usage.CacheOutcome != "" || usage.CacheTier != "" || usage.CachedTokens != 0 ||
		usage.PrefillTokensSaved != 0 || usage.CacheStageMs != 0
}
