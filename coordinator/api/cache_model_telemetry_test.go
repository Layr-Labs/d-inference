package api

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func modelCacheTestCatalog(s *Server) {
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
	srv.SetDatadog(dd)
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
			srv.holdForSettlement(pr)
			provider.RemovePending(pr.RequestID)
		}
		msg := protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: tc.usage}
		srv.handleComplete(provider.ID, provider, &msg)
		// Replayed provider terminals must not inflate model counts or tokens.
		srv.handleComplete(provider.ID, provider, &msg)
		if !tc.parked {
			got := <-pr.CompleteCh
			if validCacheUsage(tc.usage) && got.CachedTokens != tc.usage.CachedTokens {
				t.Fatalf("telemetry changed response cached tokens: %+v", got)
			}
		}
	}
	snap := srv.metrics.Snapshot()
	for _, tc := range []struct{ model, outcome, tier string }{
		{a, "hit", "ssd"}, {b, "miss_absent", "ssd"}, {c, "hit", "ssd"}, {a, "invalid", "none"}, {b, "unreported", "none"},
	} {
		key := metricKey("cache_model_usage_total", []MetricLabel{{"model", tc.model}, {"outcome", tc.outcome}, {"tier", tc.tier}})
		if snap.Counters[key] != 1 {
			t.Fatalf("%s = %d, want 1", key, snap.Counters[key])
		}
	}
	for _, model := range []string{a, c} {
		labels := []MetricLabel{{"model", model}, {"tier", "ssd"}}
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
	stageLabels := []MetricLabel{{"model", a}, {"tier", "ssd"}, {"outcome", "hit"}}
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

func TestModelCacheProofAndSelectionPopulationsStaySeparate(t *testing.T) {
	srv := &Server{registry: registry.New(quietLogger()), metrics: NewMetrics()}
	modelCacheTestCatalog(srv)
	model := "qwen3.5-35b-a3b"
	lookup := &protocol.PrefixCacheLookupV2Message{ModelID: model, Tier: "ssd", Outcome: "hit", CacheReceiptNonce: "private-nonce"}
	ready := &protocol.PrefixCacheReadyV2Message{ModelID: model, Tier: "ssd"}
	srv.emitModelCacheLookup(lookup, registry.CacheReceiptResult{Reason: registry.CacheReceiptPromptMismatch})
	srv.emitModelCacheDonation(ready, registry.CacheReceiptResult{Reason: registry.CacheReceiptLookupNotSeen})
	if len(srv.metrics.Snapshot().Counters) != 0 {
		t.Fatal("rejected proof counted as accepted")
	}
	accepted := registry.CacheReceiptResult{Accepted: true, Reason: registry.CacheReceiptAccepted}
	srv.emitModelCacheLookup(lookup, accepted)
	srv.emitModelCacheDonation(ready, accepted)
	hit := protocol.UsageInfo{PromptTokens: 4096, CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 2048, PrefillTokensSaved: 2048}
	for i, selected := range []bool{false, true} {
		pr := cacheTelemetryPending(fmt.Sprintf("private-receipt-%d", i))
		pr.Model = model
		pr.PublicModel = "private-alias"
		pr.CacheSelectionSelected = selected
		pr.CacheSelectionEstimatedTTFTSavedMs = 150.25
		if !selected {
			pr.CacheSelectionEstimatedTTFTSavedMs = 0
		}
		srv.emitCacheSelectionTerminal(pr, hit, true, true)
		srv.emitCacheSelectionTerminal(pr, hit, true, true)
		srv.emitCacheSelectionTTFT(pr, hit, true, 200)
		srv.emitCacheSelectionTTFT(pr, hit, false, 200) // invalid usage cannot produce a timing sample
	}
	missing := cacheTelemetryPending("private-disconnected")
	missing.Model = model
	srv.emitCacheSelectionTerminal(missing, protocol.UsageInfo{}, false, false)
	srv.emitCacheSelectionTerminal(missing, hit, true, true)
	snap := srv.metrics.Snapshot()
	counts := map[string]int64{}
	var estimatedUS, samples, ttftUS, ttftSamples int64
	for key, value := range snap.Counters {
		for _, prefix := range []string{"cache_model_lookup_total", "cache_model_donation_total", "cache_model_selection_total"} {
			if strings.HasPrefix(key, prefix) {
				counts[prefix] += value
			}
		}
		if strings.HasPrefix(key, "cache_model_ttft_us_total") {
			ttftUS += value
		}
		if strings.HasPrefix(key, "cache_model_ttft_samples_total") {
			ttftSamples += value
		}
		if strings.HasPrefix(key, "cache_model_estimated_ttft_saved_us_total") {
			estimatedUS += value
		}
		if strings.HasPrefix(key, "cache_model_estimated_ttft_saved_samples_total") {
			samples += value
		}
	}
	if counts["cache_model_lookup_total"] != 1 || counts["cache_model_donation_total"] != 1 || counts["cache_model_selection_total"] != 3 || estimatedUS != 150250 || samples != 1 {
		t.Fatalf("counts=%v estimatedUS=%d samples=%d", counts, estimatedUS, samples)
	}
	if ttftUS != 400000 || ttftSamples != 2 {
		t.Fatalf("TTFT sum=%d samples=%d", ttftUS, ttftSamples)
	}
	raw, _ := json.Marshal(snap)
	if !strings.Contains(string(raw), "selected=false") || !strings.Contains(string(raw), "lookup_outcome=unreported") {
		t.Fatal("selection coverage populations collapsed")
	}
	for _, secret := range []string{"private-", "secret-route"} {
		if strings.Contains(string(raw), secret) {
			t.Fatalf("metrics leaked %s", secret)
		}
	}
}

func TestModelCacheLabelsRequireExplicitCatalogMembership(t *testing.T) {
	srv := &Server{registry: registry.New(quietLogger()), metrics: NewMetrics()}
	const secret = "private-off-catalog-model"
	if srv.cacheModelLabel(secret) != "unknown" {
		t.Fatal("nil catalog allowed arbitrary labels")
	}
	modelCacheTestCatalog(srv)
	if srv.cacheModelLabel(secret) != "unknown" {
		t.Fatal("off-catalog label leaked")
	}
	if srv.cacheModelLabel("EigenLabs/Qwen3.8-27B-4bit-mtp") != "EigenLabs/Qwen3.8-27B-4bit-mtp" {
		t.Fatal("catalog identity lost")
	}
	for _, id := range []string{"bad|tag", "bad,tag", "bad\ntag", strings.Repeat("x", 201)} {
		srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: id}})
		if srv.cacheModelLabel(id) != "unknown" {
			t.Fatal("unsafe label allowed")
		}
	}
	for _, ms := range []float64{math.NaN(), math.Inf(1), -1, math.MaxFloat64} {
		srv.cacheModelTiming("provider_stage", ms)
	}
	if len(srv.metrics.Snapshot().Counters) != 0 {
		t.Fatal("invalid timing recorded")
	}
}
