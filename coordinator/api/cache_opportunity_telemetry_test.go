package api

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheOpportunityTelemetryIsTerminalOnceAndContainsNoPrivateIdentity(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	t.Cleanup(srv.Close)
	modelCacheTestCatalog(srv)
	pr := cacheTelemetryPending("private-request-nonce")
	pr.Model = "qwen3.5-35b-a3b"
	pr.PublicModel = "private-caller-alias"
	pr.CacheSelectionSelected = false
	pr.CacheOpportunity = registry.CacheOpportunity{Evaluated: true, RepeatedPrefixTokens: 1024}
	usage := protocol.UsageInfo{PromptTokens: 4096, CacheTier: "ssd", CacheOutcome: "miss_absent"}
	srv.emitCacheSelectionTerminal(pr, usage, true, true)
	srv.emitCacheSelectionTerminal(pr, usage, true, true)
	snap := srv.metrics.Snapshot()
	labels := []MetricLabel{{Name: "model", Value: pr.Model}, {Name: "reason", Value: "repeat_without_holder"}}
	if snap.Counters[metricKey("cache_model_opportunity_total", labels)] != 1 {
		t.Fatal("duplicate terminal counted or opportunity missing")
	}
	if snap.Counters[metricKey("cache_model_opportunity_repeated_prefix_tokens_total", labels)] != 1024 {
		t.Fatal("repeat demand denominator missing")
	}
	if snap.Counters[metricKey("cache_model_prefill_tokens_saved_total", []MetricLabel{{Name: "model", Value: pr.Model}, {Name: "tier", Value: "ssd"}})] != 0 {
		t.Fatal("demand was counted as saved work")
	}
	raw, _ := json.Marshal(snap)
	for _, secret := range []string{"private-request-nonce", "private-caller-alias"} {
		if strings.Contains(string(raw), secret) {
			t.Fatalf("private identity in telemetry: %s", secret)
		}
	}
}
