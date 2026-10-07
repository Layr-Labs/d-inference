package inference_test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	cacheusage "github.com/eigeninference/d-inference/coordinator/internal/inference/cacheusage"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func modelCacheTestCatalog(s *serverFixture) {
	s.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: "qwen3.5-35b-a3b"}, {ID: "qwen3.6-35b-a3b-vl-mtp-mxfp8"}, {ID: "EigenLabs/Qwen3.8-27B-4bit-mtp"},
	})
}

func TestModelCacheCompletionsSeparateModelsAndPreserveUsage(t *testing.T) {
	srv, _, _ := billingTestServer(t)
	t.Cleanup(srv.Close)
	modelCacheTestCatalog(srv)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.observation.SetDatadog(dd)
	const a = "qwen3.5-35b-a3b"
	const b = "qwen3.6-35b-a3b-vl-mtp-mxfp8"
	const c = "EigenLabs/Qwen3.8-27B-4bit-mtp"
	hit := protocol.UsageInfo{PromptTokens: 4096, CompletionTokens: 10, CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 3072, PrefillTokensSaved: 2048, CacheStageMs: 40.25}
	miss := protocol.UsageInfo{PromptTokens: 4096, CompletionTokens: 10, CacheOutcome: "miss_absent", CacheTier: "ssd"}
	invalid := hit
	invalid.CachedTokens = 5000
	for i, tc := range []struct {
		model  string
		usage  protocol.UsageInfo
		parked bool
	}{
		{a, hit, false}, {b, miss, false}, {c, hit, true}, {a, invalid, false},
		{b, protocol.UsageInfo{PromptTokens: 4096, CompletionTokens: 10}, false},
	} {
		provider := registerHeartbeatedProvider(t, srv, fmt.Sprintf("private-provider-%d", i), tc.model, nil)
		pr := completedPendingRequest(t, srv, provider, fmt.Sprintf("private-request-%d", i), tc.model, tc.usage)
		pr.PublicModel = "private-caller-alias"
		if tc.parked {
			srv.late.Hold(pr)
			provider.RemovePending(pr.RequestID)
		}
		msg := protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: tc.usage}
		srv.HandleCompleteAt(provider.ID, provider, &msg, time.Now())
		// Replayed provider terminals must not inflate model counts or tokens.
		srv.HandleCompleteAt(provider.ID, provider, &msg, time.Now())
		if !tc.parked {
			got := <-pr.CompleteCh
			if cacheusage.Valid(tc.usage) && got.CachedTokens != tc.usage.CachedTokens {
				t.Fatalf("telemetry changed response cached tokens: %+v", got)
			}
		}
	}
	snap := srv.observation.Metrics().Snapshot()
	for _, tc := range []struct{ model, outcome, tier string }{
		{a, "hit", "ssd"}, {b, "miss_absent", "ssd"}, {c, "hit", "ssd"}, {a, "invalid", "none"}, {b, "unreported", "none"},
	} {
		key := metricKey("cache_model_usage_total", []observation.MetricLabel{{Name: "model", Value: tc.model}, {Name: "outcome", Value: tc.outcome}, {Name: "tier", Value: tc.tier}})
		if snap.Counters[key] != 1 {
			t.Fatalf("%s = %d, want 1", key, snap.Counters[key])
		}
	}
	for _, model := range []string{a, c} {
		labels := []observation.MetricLabel{{Name: "model", Value: model}, {Name: "tier", Value: "ssd"}}
		hitLabels := []observation.MetricLabel{{Name: "model", Value: model}, {Name: "outcome", Value: "hit"}, {Name: "tier", Value: "ssd"}}
		if got := snap.Counters[metricKey("cache_model_usage_prompt_tokens_total", hitLabels)]; got != 4096 {
			t.Fatalf("hit prompt denominator for %s = %d", model, got)
		}
		if got := snap.Counters[metricKey("cache_model_usage_prefill_tokens_saved_total", hitLabels)]; got != 2048 {
			t.Fatalf("matched numerator for %s = %d", model, got)
		}
		if got := snap.Counters[metricKey("cache_model_prefill_tokens_saved_total", labels)]; got != 2048 {
			t.Fatalf("saved tokens for %s = %d", model, got)
		}
		if got := snap.Counters[metricKey("cache_model_cached_tokens_total", labels)]; got != 3072 {
			t.Fatalf("cached tokens for %s = %d", model, got)
		}
	}
	if snap.Counters["exact_cache_usage_total{outcome=hit,tier=ssd}"] != 2 || snap.Counters["exact_cache_prefill_tokens_saved_total{tier=ssd}"] != 4096 {
		t.Fatal("aggregate usage changed or invalid/duplicate usage was counted")
	}
	stageLabels := []observation.MetricLabel{{Name: "model", Value: a}, {Name: "tier", Value: "ssd"}, {Name: "outcome", Value: "hit"}}
	if snap.Counters[metricKey("cache_model_provider_stage_us_total", stageLabels)] != 40250 || snap.Counters[metricKey("cache_model_provider_stage_samples_total", stageLabels)] != 1 {
		t.Fatal("provider stage sum/sample counters are wrong")
	}
	for key := range snap.Counters {
		if strings.HasPrefix(key, "cache_model_lookup_total") {
			t.Fatal("provider usage fabricated proof-backed hits")
		}
	}
	_ = dd.Statsd.Flush()
	packets := collector.drain()
	if !hasMetric(findMetrics(packets, "routing.cache_model.usage"), "model:"+a) || !hasMetric(findMetrics(packets, "routing.cache_model.prefill_tokens_saved"), "model:"+c) {
		t.Fatalf("model metrics absent from Datadog: %v", packets)
	}
	modelPackets := findMetrics(packets, "routing.cache_model.")
	for _, secret := range []string{"private-caller-alias", "private-provider-", "private-request-"} {
		if strings.Contains(strings.Join(modelPackets, "\n"), secret) {
			t.Fatalf("model metrics leaked %s", secret)
		}
	}
}
