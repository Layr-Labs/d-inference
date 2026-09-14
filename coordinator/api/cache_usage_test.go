package api

import (
	"strings"
	"testing"

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
	if validCacheUsage(usage) {
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
	if validCacheUsage(usage) {
		t.Fatal("cache fields without outcome were accepted")
	}
	clearCacheUsage(&usage)
	if hasCacheUsage(usage) {
		t.Fatalf("invalid cache fields survived sanitization: %+v", usage)
	}
}

func TestCacheSelectionTerminalTagsAreLowCardinalityAndCorrelated(t *testing.T) {
	pr := &registry.PendingRequest{
		CachePlan:          testCachePlan("secret-route-key"),
		CacheSelectionMode: "active", CacheSelectionTier: "ssd",
		CacheSelectionDiscountMs: 42,
	}
	tags := cacheSelectionTerminalTags(pr, protocol.UsageInfo{CacheOutcome: "miss_absent"}, true, true)
	joined := strings.Join(tags, ",")
	for _, want := range []string{"mode:active", "tier:ssd", "selected:false", "result:non_hit"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("terminal selection tags %q missing %q", joined, want)
		}
	}
	if strings.Contains(joined, "secret-route-key") {
		t.Fatalf("terminal selection tags leaked a route key: %q", joined)
	}
	invalid := strings.Join(cacheSelectionTerminalTags(pr, protocol.UsageInfo{}, false, true), ",")
	if !strings.Contains(invalid, "result:invalid") {
		t.Fatalf("invalid terminal usage was not correlated: %q", invalid)
	}
}

func TestValidProviderCacheUsageShapes(t *testing.T) {
	if !validCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "hit", CacheTier: "memory", CachedTokens: 80, PrefillTokensSaved: 64, CacheStageMs: 1}) {
		t.Fatal("valid hit usage rejected")
	}
	if !validCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CacheStageMs: 1}) {
		t.Fatal("valid miss usage rejected")
	}
	if validCacheUsage(protocol.UsageInfo{PromptTokens: 100, CacheOutcome: "miss_absent", CachedTokens: 1}) {
		t.Fatal("non-hit usage with cached tokens accepted")
	}
}
