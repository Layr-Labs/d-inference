package providerframe

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestInvalidProviderCacheUsageIsCleared(t *testing.T) {
	usage := protocol.UsageInfo{
		PromptTokens: 10, CompletionTokens: 2,
		CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 20,
		PrefillTokensSaved: 19, CacheStageMs: 3,
	}
	if ValidCacheUsage(usage) {
		t.Fatal("impossible cached_tokens > prompt_tokens accepted")
	}
	clearCacheUsage(&usage)
	if usage.CacheOutcome != "" || usage.CacheTier != "" || usage.CachedTokens != 0 || usage.PrefillTokensSaved != 0 || usage.CacheStageMs != 0 {
		t.Fatalf("cache extension was not cleared: %+v", usage)
	}
	if usage.PromptTokens != 10 || usage.CompletionTokens != 2 {
		t.Fatalf("base completion usage was changed: %+v", usage)
	}
}

func TestOmittedOutcomeWithCacheFieldsRequiresSanitization(t *testing.T) {
	usage := protocol.UsageInfo{PromptTokens: 10, CachedTokens: 20, PrefillTokensSaved: 19}
	if !hasCacheUsage(usage) {
		t.Fatal("cache fields without outcome were not detected")
	}
	if ValidCacheUsage(usage) {
		t.Fatal("cache fields without outcome were accepted")
	}
	clearCacheUsage(&usage)
	if hasCacheUsage(usage) {
		t.Fatalf("invalid cache fields survived sanitization: %+v", usage)
	}
}

func TestValidProviderCacheUsageShapes(t *testing.T) {
	if !ValidCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "hit", CacheTier: "memory", CachedTokens: 80, PrefillTokensSaved: 64, CacheStageMs: 1}) {
		t.Fatal("valid hit usage rejected")
	}
	if !ValidCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CacheStageMs: 1}) {
		t.Fatal("valid miss usage rejected")
	}
	if ValidCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CachedTokens: 1}) {
		t.Fatal("non-hit usage with cached tokens accepted")
	}
}
