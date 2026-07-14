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
		CacheRoute:         registry.CacheRoute{ExactKey: "must-not-be-tagged-route"},
		CacheSelectionMode: "active", CacheSelectionKind: "exact", CacheSelectionTier: "ssd",
		CacheSelectionSelected: true,
	}
	usage := protocol.UsageInfo{CacheOutcome: "miss_absent"}
	value, tags, ok := cacheSelectionTTFTSample(pr, usage, true, 321.5)
	if !ok || value != 321.5 {
		t.Fatalf("sample = %v tags=%v ok=%t, want 321.5", value, tags, ok)
	}
	joined := strings.Join(tags, ",")
	for _, want := range []string{"mode:active", "kind:exact", "tier:ssd", "selected:true", "result:non_hit"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("TTFT tags %q missing %q", joined, want)
		}
	}
	for _, secret := range []string{pr.RequestID, pr.CacheRoute.ExactKey} {
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

func TestObserveCacheSelectionTTFTIsBaselineNotPrecision(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv := &Server{}
	srv.SetDatadog(ddClient)

	pr := &registry.PendingRequest{
		CacheRoute:         registry.CacheRoute{ExactKey: "secret"},
		CacheSelectionMode: "observe", CacheSelectionKind: "conversation_explicit", CacheSelectionTier: "memory",
		CacheSelectionSelected: true, CacheSelectionWouldChange: true,
	}
	usage := protocol.UsageInfo{CacheOutcome: "miss_absent"}
	srv.emitCacheSelectionTerminal(pr, usage, true, true)
	srv.emitCacheSelectionTTFT(pr, usage, true, 250)
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "routing.cache_selection_ttft_ms:250") || !hasMetric(packets, "selected:false") || !hasMetric(packets, "result:non_hit") {
		t.Fatalf("observe TTFT was not emitted as baseline-only: %v", packets)
	}
	if hasMetric(packets, "routing.cache_selection_precision") {
		t.Fatalf("observe hypothetical candidate emitted a precision metric: %v", packets)
	}
}
