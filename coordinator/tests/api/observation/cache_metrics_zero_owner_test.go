package observation_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestModelCacheMetricsZeroOwnerRetainsNilMetricBehavior(t *testing.T) {
	o := &observation.Owner{}
	pr := &registry.PendingRequest{Model: "off-catalog", CacheSelectionMode: "active"}
	u := protocol.UsageInfo{PromptTokens: 128, CacheOutcome: "hit", CacheTier: "ssd"}
	o.EmitModelCacheUsage(pr, u, true, true)
	o.EmitModelCacheLookup(&protocol.PrefixCacheLookupV2Message{ModelID: pr.Model}, registry.CacheReceiptResult{Accepted: true})
	o.EmitCacheSelectionTTFT(pr, u, true, 10)
	if o.Metrics() != nil {
		t.Fatal("zero owner fabricated a metric registry")
	}
}
