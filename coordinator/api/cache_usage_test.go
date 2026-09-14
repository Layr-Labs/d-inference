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
