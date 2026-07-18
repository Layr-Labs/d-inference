package api

import (
	"math"
	"strconv"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheSelectionTTFTSampleActiveNonHit(t *testing.T) {
	pr := &registry.PendingRequest{
		RequestID:          "must-not-be-tagged",
		CachePlan:          testCachePlan("must-not-be-tagged-route"),
		CacheSelectionMode: "active", CacheSelectionTier: "ssd",
		CacheSelectionSelected: true,
	}
	usage := protocol.UsageInfo{CacheOutcome: "miss_absent"}
	value, tags, ok := cacheSelectionTTFTSample(pr, usage, true, 321.5)
	if !ok || value != 321.5 {
		t.Fatalf("sample = %v tags=%v ok=%t, want 321.5", value, tags, ok)
	}
	joined := strings.Join(tags, ",")
	for _, want := range []string{"mode:active", "tier:ssd", "selected:true", "result:non_hit"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("TTFT tags %q missing %q", joined, want)
		}
	}
	for _, secret := range []string{pr.RequestID, pr.CachePlan.ModelAggregateHash} {
		if strings.Contains(joined, secret) {
			t.Fatalf("TTFT tags leaked identifier %q: %q", secret, joined)
		}
	}
}

func TestCacheSelectionTTFTSampleRejectsUnauthoritativeInputs(t *testing.T) {
	pr := &registry.PendingRequest{CacheSelectionMode: "active", CacheSelectionSelected: true}
	usage := protocol.UsageInfo{CacheOutcome: "miss_absent"}
	for _, tc := range []struct {
		name  string
		valid bool
		ttft  float64
	}{
		{name: "invalid_usage", valid: false, ttft: 100},
		{name: "missing_timing", valid: true, ttft: 0},
		{name: "negative_timing", valid: true, ttft: -1},
		{name: "nan_timing", valid: true, ttft: math.NaN()},
		{name: "infinite_timing", valid: true, ttft: math.Inf(1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, _, ok := cacheSelectionTTFTSample(pr, usage, tc.valid, tc.ttft); ok {
				t.Fatal("emitted unauthoritative TTFT sample")
			}
		})
	}
}

func TestCacheSelectionTerminalCorrelationCoversEveryLookupOutcome(t *testing.T) {
	pr := &registry.PendingRequest{
		RequestID: "private-request-id", ProviderID: "private-provider-id",
		ConsumerKey: "private-account-id",
		CachePlan: registry.CachePlan{
			ModelAggregateHash: strings.Repeat("a", 64),
			PromptContractID:   strings.Repeat("b", 64),
			CacheScope:         "private-cache-scope",
			PromptTokenCount:   512,
			Boundaries: []protocol.PrefixCacheAnchor{{
				TokenCount: 256, ChainHash: strings.Repeat("c", 64),
			}},
		},
		CacheSelectionMode: "active", CacheSelectionTier: "ssd",
		CacheSelectionSelected: true,
	}
	outcomes := []string{
		"hit", "miss_absent", "miss_corrupt",
		"skipped_capacity", "skipped_cost", "skipped_policy",
	}
	for _, outcome := range outcomes {
		t.Run(outcome, func(t *testing.T) {
			tags := cacheSelectionTerminalTags(
				pr, protocol.UsageInfo{CacheOutcome: outcome}, true, true)
			joined := strings.Join(tags, ",")
			for _, want := range []string{
				"selected:true",
				"lookup_outcome:" + outcome,
				"cache_read:" + strconv.FormatBool(outcome == "hit"),
			} {
				if !strings.Contains(joined, want) {
					t.Fatalf("tags %q missing %q", joined, want)
				}
			}
			for _, sensitive := range []string{
				pr.RequestID, pr.ProviderID, pr.ConsumerKey,
				pr.CachePlan.ModelAggregateHash, pr.CachePlan.PromptContractID,
				pr.CachePlan.CacheScope, pr.CachePlan.Boundaries[0].ChainHash,
			} {
				if strings.Contains(joined, sensitive) {
					t.Fatalf("terminal correlation leaked %q in %q", sensitive, joined)
				}
			}
		})
	}
	for _, tc := range []struct {
		name, outcome  string
		valid, present bool
	}{
		{name: "unreported", outcome: "unreported"},
		{name: "invalid", outcome: "invalid", present: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tags := cacheSelectionTerminalTags(pr, protocol.UsageInfo{}, tc.valid, tc.present)
			joined := strings.Join(tags, ",")
			if !strings.Contains(joined, "lookup_outcome:"+tc.outcome) ||
				!strings.Contains(joined, "cache_read:false") {
				t.Fatalf("tags=%q", joined)
			}
		})
	}
}
