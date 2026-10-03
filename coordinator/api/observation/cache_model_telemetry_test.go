package observation

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func modelCacheTestCatalog(s *Owner) {
	s.registry.SetModelCatalog([]registry.CatalogEntry{
		{ID: "qwen3.5-35b-a3b"}, {ID: "qwen3.6-35b-a3b-vl-mtp-mxfp8"}, {ID: "EigenLabs/Qwen3.8-27B-4bit-mtp"},
	})
}

func TestModelCacheProofAndSelectionPopulationsStaySeparate(t *testing.T) {
	srv := &Owner{registry: registry.New(quietLogger()), metrics: NewMetrics()}
	modelCacheTestCatalog(srv)
	model := "qwen3.5-35b-a3b"
	lookup := &protocol.PrefixCacheLookupV2Message{ModelID: model, Tier: "ssd", Outcome: "hit", CacheReceiptNonce: "private-nonce"}
	ready := &protocol.PrefixCacheReadyV2Message{ModelID: model, Tier: "ssd"}
	srv.EmitModelCacheLookup(lookup, registry.CacheReceiptResult{Reason: registry.CacheReceiptPromptMismatch})
	srv.EmitModelCacheDonation(ready, registry.CacheReceiptResult{Reason: registry.CacheReceiptLookupNotSeen})
	if len(srv.Metrics().Snapshot().Counters) != 0 {
		t.Fatal("rejected proof counted as accepted")
	}
	accepted := registry.CacheReceiptResult{Accepted: true, Reason: registry.CacheReceiptAccepted}
	srv.EmitModelCacheLookup(lookup, accepted)
	srv.EmitModelCacheDonation(ready, accepted)
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
		srv.EmitCacheSelectionTerminal(pr, hit, true, true)
		srv.EmitCacheSelectionTerminal(pr, hit, true, true)
		srv.EmitCacheSelectionTTFT(pr, hit, true, 200)
		srv.EmitCacheSelectionTTFT(pr, hit, false, 200) // invalid usage cannot produce a timing sample
	}
	missing := cacheTelemetryPending("private-disconnected")
	missing.Model = model
	srv.EmitCacheSelectionTerminal(missing, protocol.UsageInfo{}, false, false)
	srv.EmitCacheSelectionTerminal(missing, hit, true, true)
	snap := srv.Metrics().Snapshot()
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
	srv := &Owner{registry: registry.New(quietLogger()), metrics: NewMetrics()}
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
	if len(srv.Metrics().Snapshot().Counters) != 0 {
		t.Fatal("invalid timing recorded")
	}
}

func TestModelCacheCoverageSeparatesHitAndNonHitDenominators(t *testing.T) {
	srv := &Owner{registry: registry.New(quietLogger()), metrics: NewMetrics()}
	modelCacheTestCatalog(srv)
	const model = "qwen3.5-35b-a3b"
	pr := &registry.PendingRequest{Model: model}
	srv.EmitModelCacheUsage(pr, protocol.UsageInfo{PromptTokens: 8192, CachedTokens: 4096, PrefillTokensSaved: 4096, CacheOutcome: "hit", CacheTier: "ssd"}, true, true)
	srv.EmitModelCacheUsage(pr, protocol.UsageInfo{PromptTokens: 16384, CacheOutcome: "miss_absent", CacheTier: "ssd"}, true, true)
	for _, count := range []int{-1, 0, 1_000_001} {
		srv.EmitModelCacheUsage(pr, protocol.UsageInfo{PromptTokens: count, CacheOutcome: "miss_absent", CacheTier: "ssd"}, true, true)
	}
	srv.EmitModelCacheUsage(pr, protocol.UsageInfo{PromptTokens: 8192}, false, false)
	srv.EmitModelCacheUsage(pr, protocol.UsageInfo{PromptTokens: 8192, CacheOutcome: "invalid"}, false, true)
	snap := srv.Metrics().Snapshot()
	for _, tc := range []struct {
		outcome       string
		prompt, saved int64
	}{
		{"hit", 8192, 4096}, {"miss_absent", 16384, 0}, {"invalid", 0, 0}, {"unreported", 0, 0},
	} {
		labels := []MetricLabel{{"model", model}, {"outcome", tc.outcome}, {"tier", "ssd"}}
		if got := snap.Counters[metricKey("cache_model_usage_prompt_tokens_total", labels)]; got != tc.prompt {
			t.Fatalf("%s denominator = %d", tc.outcome, got)
		}
		if got := snap.Counters[metricKey("cache_model_usage_prefill_tokens_saved_total", labels)]; got != tc.saved {
			t.Fatalf("%s numerator = %d", tc.outcome, got)
		}
	}
}

func TestModelCacheAcceptedLookupAndSelectedCoverage(t *testing.T) {
	srv := &Owner{registry: registry.New(quietLogger()), metrics: NewMetrics()}
	modelCacheTestCatalog(srv)
	const model = "qwen3.5-35b-a3b"
	lookup := &protocol.PrefixCacheLookupV2Message{ModelID: model, Tier: "ssd", Outcome: "hit", ExpectedPrefillTokensSaved: 4096}
	srv.EmitModelCacheLookup(lookup, registry.CacheReceiptResult{Accepted: true, Reason: registry.CacheReceiptAccepted, PromptTokens: 8192})
	srv.EmitModelCacheLookup(lookup, registry.CacheReceiptResult{Reason: registry.CacheReceiptPromptMismatch})
	pr := cacheTelemetryPending("private-selection-coverage")
	pr.Model = model
	pr.CacheSelectionSelected = true
	usage := protocol.UsageInfo{PromptTokens: 8192, CachedTokens: 4096, PrefillTokensSaved: 4096, CacheOutcome: "hit", CacheTier: "ssd"}
	srv.EmitCacheSelectionTerminal(pr, usage, true, true)
	srv.EmitCacheSelectionTerminal(pr, usage, true, true)
	lookupLabels := []MetricLabel{{"model", model}, {"tier", "ssd"}, {"outcome", "hit"}}
	selectionLabels := srv.cacheModelSelectionLabels(model, cacheSelectionTerminalTags(pr, usage, true, true))
	for _, tc := range []struct {
		name   string
		labels []MetricLabel
	}{{"lookup", lookupLabels}, {"selection", selectionLabels}} {
		snap := srv.Metrics().Snapshot()
		if got := snap.Counters[metricKey("cache_model_"+tc.name+"_prompt_tokens_total", tc.labels)]; got != 8192 {
			t.Fatalf("%s denominator=%d", tc.name, got)
		}
		if got := snap.Counters[metricKey("cache_model_"+tc.name+"_prefill_tokens_saved_total", tc.labels)]; got != 4096 {
			t.Fatalf("%s numerator=%d", tc.name, got)
		}
	}
}

func TestModelCacheReceiptDiagnosticsUseBoundedLabelsWithoutCountingHits(t *testing.T) {
	srv := &Owner{registry: registry.New(quietLogger()), metrics: NewMetrics()}
	modelCacheTestCatalog(srv)
	srv.EmitModelCacheReceipt("private-model|tag", "private-tier", "lookup_v2", registry.CacheReceiptResult{
		Reason: registry.CacheReceiptPromptMismatch, PromptMismatch: registry.CachePromptHashMismatch,
	})
	snap := srv.Metrics().Snapshot()
	if snap.Counters["cache_model_prompt_mismatch_total{detail=same_length_hash,model=unknown,tier=none}"] != 1 {
		t.Fatalf("missing bounded diagnostic: %v", snap.Counters)
	}
	raw, _ := json.Marshal(snap)
	if strings.Contains(string(raw), "private-") || strings.Contains(string(raw), "cache_model_lookup_total") || strings.Contains(string(raw), "prompt_tokens") {
		t.Fatalf("rejection leaked identity, counted a hit or fabricated a denominator: %s", raw)
	}
}
