package providerframe

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// ValidCacheUsage checks the provider extension before cache telemetry consumes it.
func ValidCacheUsage(usage protocol.UsageInfo) bool {
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

func clearCacheUsage(usage *protocol.UsageInfo) {
	if usage == nil {
		return
	}
	usage.CacheOutcome = ""
	usage.CacheTier = ""
	usage.CachedTokens = 0
	usage.PrefillTokensSaved = 0
	usage.CacheStageMs = 0
}

func hasCacheUsage(usage protocol.UsageInfo) bool {
	return usage.CacheOutcome != "" || usage.CacheTier != "" || usage.CachedTokens != 0 ||
		usage.PrefillTokensSaved != 0 || usage.CacheStageMs != 0
}
