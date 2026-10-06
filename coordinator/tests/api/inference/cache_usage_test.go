package inference_test

import (
	"strings"
	"testing"

	cacheusage "github.com/eigeninference/d-inference/coordinator/internal/inference/cacheusage"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func testCachePlan(secret string) registry.CachePlan {
	return registry.CachePlan{
		ModelAggregateHash: secret,
		PromptContractID:   "contract",
		CacheScope:         "scope",
		PromptTokenCount:   64,
		Boundaries: []protocol.PrefixCacheAnchor{{
			TokenCount: 64,
			ChainHash:  strings.Repeat("a", 64),
		}},
	}
}

func TestInvalidProviderCacheUsageIsCleared(t *testing.T) {
	usage := protocol.UsageInfo{
		PromptTokens: 10, CompletionTokens: 2,
		CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 20,
		PrefillTokensSaved: 19, CacheStageMs: 3,
	}
	if cacheusage.Valid(usage) {
		t.Fatal("impossible cached_tokens > prompt_tokens accepted")
	}
	cacheusage.Clear(&usage)
	if usage.CacheOutcome != "" || usage.CacheTier != "" || usage.CachedTokens != 0 || usage.PrefillTokensSaved != 0 || usage.CacheStageMs != 0 {
		t.Fatalf("cache extension was not cleared: %+v", usage)
	}
	if usage.PromptTokens != 10 || usage.CompletionTokens != 2 {
		t.Fatalf("base completion usage was changed: %+v", usage)
	}
}

func TestOmittedOutcomeWithCacheFieldsRequiresSanitization(t *testing.T) {
	usage := protocol.UsageInfo{PromptTokens: 10, CachedTokens: 20, PrefillTokensSaved: 19}
	if !cacheusage.Has(usage) {
		t.Fatal("cache fields without outcome were not detected")
	}
	if cacheusage.Valid(usage) {
		t.Fatal("cache fields without outcome were accepted")
	}
	cacheusage.Clear(&usage)
	if cacheusage.Has(usage) {
		t.Fatalf("invalid cache fields survived sanitization: %+v", usage)
	}
}

func TestValidProviderCacheUsageShapes(t *testing.T) {
	if !cacheusage.Valid(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "hit", CacheTier: "memory", CachedTokens: 80, PrefillTokensSaved: 64, CacheStageMs: 1}) {
		t.Fatal("valid hit usage rejected")
	}
	if !cacheusage.Valid(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CacheStageMs: 1}) {
		t.Fatal("valid miss usage rejected")
	}
	if cacheusage.Valid(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CachedTokens: 1}) {
		t.Fatal("non-hit usage with cached tokens accepted")
	}
}
