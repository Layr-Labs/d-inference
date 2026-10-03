package observation

import (
	"fmt"
	"math"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestExactCacheOperationalMetricsAreCompleteAndPrivacySafe(t *testing.T) {
	server := &Owner{metrics: NewMetrics()}
	server.EmitExactCachePlan(registry.CachePlanResult{Outcome: registry.CachePlanSampledOut})
	server.EmitExactCachePlan(registry.CachePlanResult{
		Outcome: registry.CachePlanColdOnly, PlanLatency: 4 * time.Millisecond, SidecarCalled: true,
	})
	server.EmitExactCachePlan(registry.CachePlanResult{
		Outcome: registry.CachePlanPlanned, PlanLatency: 12 * time.Millisecond, SidecarCalled: true,
	})
	server.EmitExactCacheSSDLookup("v2", "miss_absent", 3)
	server.EmitExactCacheSSDLookup("v2", "hit", 2)
	server.EmitExactCacheSSDDonation("v2", 8, 512)
	server.EmitExactCacheUsage("hit", "ssd", 512, 496, 2)
	request := &registry.PendingRequest{
		RequestID: "private-request", ConsumerKey: "private-account",
		CachePlan: registry.CachePlan{
			ModelAggregateHash: strings.Repeat("a", 64),
			PromptContractID:   strings.Repeat("b", 64),
			CacheScope:         "private-scope",
			PromptTokenCount:   512,
			Boundaries: []protocol.PrefixCacheAnchor{{
				TokenCount: 512, ChainHash: strings.Repeat("c", 64),
			}},
		},
		CacheSelectionTier:                 "ssd",
		CacheSelectionEstimatedTTFTSavedMs: 240,
	}
	server.EmitExactCacheEstimatedTTFTSaved(request, []string{"tier:ssd"})
	request.CacheSelectionEstimatedTTFTSavedMs = math.Inf(1)
	server.EmitExactCacheEstimatedTTFTSaved(request, []string{"tier:ssd"})

	snapshot := server.Metrics().Snapshot()
	for _, key := range []string{
		"exact_cache_plan_total{outcome=sampled_out}",
		"exact_cache_plan_total{outcome=cold_only}",
		"exact_cache_plan_total{outcome=planned}",
		"exact_cache_ssd_lookup_total{outcome=miss_absent,protocol=v2}",
		"exact_cache_ssd_lookup_total{outcome=hit,protocol=v2}",
		"exact_cache_ssd_donation_total{protocol=v2}",
		"exact_cache_ssd_donated_tokens_total{protocol=v2}",
		"exact_cache_usage_total{outcome=hit,tier=ssd}",
		"exact_cache_cached_tokens_total{tier=ssd}",
		"exact_cache_prefill_tokens_saved_total{tier=ssd}",
	} {
		if _, ok := snapshot.Counters[key]; !ok {
			t.Fatalf("missing counter %q in %+v", key, snapshot.Counters)
		}
	}
	for _, key := range []string{
		"exact_cache_plan_latency_ms{outcome=planned}",
		"exact_cache_plan_latency_ms{outcome=cold_only}",
		"exact_cache_ssd_stage_ms{event=lookup,outcome=hit}",
		"exact_cache_ssd_stage_ms{event=donation}",
		"exact_cache_provider_stage_ms{outcome=hit,tier=ssd}",
		"exact_cache_estimated_ttft_saved_ms{tier=ssd}",
	} {
		if _, ok := snapshot.Histograms[key]; !ok {
			t.Fatalf("missing histogram %q in %+v", key, snapshot.Histograms)
		}
	}
	if got := snapshot.Histograms["exact_cache_estimated_ttft_saved_ms{tier=ssd}"].Count; got != 1 {
		t.Fatalf("non-finite TTFT estimate was recorded: count=%d", got)
	}
	encoded := fmt.Sprintf("%v%v%v", snapshot.Counters, snapshot.Histograms, snapshot.Gauges)
	for _, sensitive := range []string{
		request.RequestID, request.ConsumerKey, request.CachePlan.CacheScope,
		request.CachePlan.ModelAggregateHash, request.CachePlan.PromptContractID,
		request.CachePlan.Boundaries[0].ChainHash,
	} {
		if strings.Contains(encoded, sensitive) {
			t.Fatalf("operational metrics leaked %q: %s", sensitive, encoded)
		}
	}
}

func TestCacheReceiptDiagnosticsDistinguishProofAndProviderUsage(t *testing.T) {
	s := &Owner{metrics: NewMetrics()}
	s.EmitCacheReceiptResult("lookup_v2", registry.CacheReceiptResult{Reason: registry.CacheReceiptPromptMismatch})
	s.EmitCacheReceiptResult("ready_v2", registry.CacheReceiptResult{Accepted: true, Reason: registry.CacheReceiptAccepted})
	s.EmitExactCacheUsage("hit", "ssd", 4096, 4096, 50)
	snap := s.Metrics().Snapshot()
	for _, key := range []string{"exact_cache_receipt_total{outcome=rejected,reason=prompt_anchor_mismatch,type=lookup_v2}", "exact_cache_receipt_total{outcome=accepted,reason=accepted,type=ready_v2}"} {
		if snap.Counters[key] != 1 {
			t.Fatalf("missing receipt diagnostic %s: %+v", key, snap.Counters)
		}
	}
	if snap.Counters["exact_cache_ssd_lookup_total{outcome=hit,protocol=v2}"] != 0 {
		t.Fatal("provider usage was mislabeled as a verified lookup hit")
	}
}
