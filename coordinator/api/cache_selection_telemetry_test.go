package api

import (
	"math"
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
