package inference_test

import (
	"bufio"
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// funnelPlanBoundary is the single boundary of the fixture sidecar's plan:
// the prompt anchor every lookup receipt must prove, and the only anchor a
// provider can publish or match.
func funnelPlanBoundary() protocol.PrefixCacheAnchor {
	return protocol.PrefixCacheAnchor{TokenCount: 256, ChainHash: strings.Repeat("c", 64)}
}

// sendLookupReceipt writes the nonce-bound SSD lookup receipt a real provider
// sends before its terminal, for the attempt it was just handed.
func (f *cacheFunnelFixture) sendLookupReceipt(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, outcome string) {
	capability, boundary := f.capabilities[fp.registryID], funnelPlanBoundary()
	receipt := protocol.PrefixCacheLookupV2Message{
		Type: protocol.TypePrefixCacheLookupV2, RequestID: req.RequestID, CacheReceiptNonce: req.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: f.receiptSeq.Add(1), PromptAnchor: boundary, Outcome: outcome, Tier: "ssd", StageMs: 1,
	}
	if outcome == "hit" {
		receipt.MatchedAnchor, receipt.ExpectedPrefillTokensSaved = &boundary, boundary.TokenCount
	}
	writeProviderJSON(fp.t, ctx, fp.conn, receipt)
}

// sendReadyReceipt publishes the plan's boundary as a durable SSD checkpoint,
// which makes the sending provider a holder for the next identical prompt.
func (f *cacheFunnelFixture) sendReadyReceipt(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage) {
	capability, boundary := f.capabilities[fp.registryID], funnelPlanBoundary()
	writeProviderJSON(fp.t, ctx, fp.conn, protocol.PrefixCacheReadyV2Message{
		Type: protocol.TypePrefixCacheReadyV2, RequestID: req.RequestID, CacheReceiptNonce: req.CacheReceiptNonce,
		ModelID: capability.ModelID, ModelAggregateHash: capability.ModelAggregateHash,
		PromptContractID: capability.PromptContractID, CacheEpoch: capability.CacheEpoch,
		CacheSeq: f.receiptSeq.Add(1), Outcome: "ready", Tier: "ssd", ReadyAnchors: []protocol.PrefixCacheAnchor{boundary},
		ExpectedPrefillTokensSaved: boundary.TokenCount, StageMs: 1,
	})
}

// leaveAfterFirstContent posts a streaming chat request and abandons it as
// soon as the provider's content has reached the client. Content delivered is
// what commits a request, so the provider's later completion is still settled
// after the client has gone.
func (f *cacheFunnelFixture) leaveAfterFirstContent(t *testing.T, body string) {
	t.Helper()
	ctx, cancel := context.WithCancel(f.ctx)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, f.transport.URL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer test-key")
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	stream := bufio.NewScanner(response.Body)
	for stream.Scan() {
		// The prefix every provider's content marker shares.
		if strings.Contains(stream.Text(), markerFor("")) {
			return
		}
	}
	t.Fatalf("the stream ended before any provider content arrived (status %d): %v", response.StatusCode, stream.Err())
}

// The two provider-stage outcomes that need routing to SELECT a holder. The
// first request seeds one: its provider misses, then publishes the prompt's
// boundary. The same prompt is then routed back to that provider, which either
// restores from SSD (hit) or is abandoned by its client (cancelled after
// dispatch).
func TestCacheFunnelFollowsASelectedHolder(t *testing.T) {
	f := newCacheFunnelFixture(t)
	chat := cachePlanningEndpointBody(cacheFunnelModel, "/v1/chat/completions", false)
	served := make(chan string, 4)

	f.serveWith(func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
		served <- fp.registryID
		fp.sendRoleChunk(ctx, req, cacheFunnelModel)
		fp.sendContentChunk(ctx, req, cacheFunnelModel, markerFor(fp.name))
		f.sendLookupReceipt(ctx, fp, req, "miss_absent")
		f.sendReadyReceipt(ctx, fp, req)
		fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 257, CompletionTokens: 3, CacheOutcome: "miss_absent", CacheTier: "ssd"})
	})
	before := f.settled(t)
	if status := f.post(t, "/v1/chat/completions", chat); status != http.StatusOK {
		t.Fatalf("seed status = %d", status)
	}
	holder := <-served
	seeded := f.settled(t)
	requireOneMoreRequest(t, before, seeded, cachefunnel.NoRepeatObserved, 1)
	awaitCondition(t, 5*time.Second, func() bool { return f.server.ExactCacheStatusSnapshot().Holders == 1 },
		"the seeding provider recorded as the prompt's holder")

	t.Run("a repeated prompt routed to its holder that restores from SSD ends as hit", func(t *testing.T) {
		f.serveWith(func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			served <- fp.registryID
			fp.sendRoleChunk(ctx, req, cacheFunnelModel)
			fp.sendContentChunk(ctx, req, cacheFunnelModel, markerFor(fp.name))
			f.sendLookupReceipt(ctx, fp, req, "hit")
			fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 257, CompletionTokens: 3,
				CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 256, PrefillTokensSaved: 192})
		})
		before, lifecycleBefore := f.settled(t), f.reg.CacheRoutingLifecycleStatus()
		if status := f.post(t, "/v1/chat/completions", chat); status != http.StatusOK {
			t.Fatalf("status = %d", status)
		}
		if got := <-served; got != holder {
			t.Fatalf("the repeated prompt went to %s, want its holder %s", got, holder)
		}
		after := f.settled(t)
		requireOneMoreRequest(t, before, after, cachefunnel.Hit, 1)
		hit, total := cacheFunnelReason(after, cachefunnel.Hit), after.Total
		if hit.SSDHitRequests != 1 || hit.MemoryHitRequests != 0 || hit.Planned != 1 || hit.Dispatched != 1 || hit.LookupOutcomeReported != 1 ||
			hit.PredictedTokensUnknown != 0 || hit.ReusedTokensUnknown != 0 || hit.PrefillSavedTokensUnknown != 0 || hit.ProviderPromptTokensUnknown != 0 {
			t.Fatalf("hit = %+v, want one planned, dispatched SSD hit with every token quantity observed", hit)
		}
		if total.SSDHitRequests != 1 || total.MemoryHitRequests != 0 {
			t.Fatalf("total = %+v, want the SSD hit and no memory hit", total)
		}
		// The funnel's SSD hits and the receipt-driven lifecycle counter agree
		// when every attempt completed and every receipt was accepted.
		awaitCondition(t, 5*time.Second, func() bool {
			return f.reg.CacheRoutingLifecycleStatus().SSDHits == lifecycleBefore.SSDHits+1
		}, "the hit lookup receipt counted as an SSD hit")
		// Routing predicted the holder's whole anchor; the provider reused it
		// and skipped part of the prefill. Exact sums stay on the admin metrics.
		for key, want := range map[string]int64{
			"exact_cache_funnel_predicted_tokens_total{reason=hit}":              256,
			"exact_cache_funnel_prompt_tokens_total{reason=hit}":                 257,
			"exact_cache_funnel_provider_prompt_tokens_total{reason=hit}":        257,
			"exact_cache_funnel_reused_tokens_total{reason=hit,tier=ssd}":        256,
			"exact_cache_funnel_prefill_saved_tokens_total{reason=hit,tier=ssd}": 192,
		} {
			f.awaitCounter(t, key, want)
		}
		// Read after the SSD sums of the same record have landed.
		const memoryKey = "exact_cache_funnel_reused_tokens_total{reason=hit,tier=memory}"
		if memory := f.server.observation.Metrics().Snapshot().Counters[memoryKey]; memory != 0 {
			t.Fatalf("memory reused tokens = %d, want none for an SSD hit", memory)
		}
	})

	t.Run("a client that leaves a selected holder ends as cancelled_after_dispatch, and the late completion is counted", func(t *testing.T) {
		release := make(chan struct{})
		f.serveWith(func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			fp.sendRoleChunk(ctx, req, cacheFunnelModel)
			fp.sendContentChunk(ctx, req, cacheFunnelModel, markerFor(fp.name))
			served <- fp.registryID
			<-release
			f.sendLookupReceipt(ctx, fp, req, "hit")
			fp.sendComplete(ctx, req, protocol.UsageInfo{PromptTokens: 257, CompletionTokens: 3,
				CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 256, PrefillTokensSaved: 256})
		})
		defer f.serveWith(fullServeScript(cacheFunnelModel))
		before := f.settled(t)
		f.leaveAfterFirstContent(t, strings.Replace(chat, `"stream":false`, `"stream":true`, 1))
		if got := <-served; got != holder {
			t.Fatalf("the repeated prompt went to %s, want its holder %s", got, holder)
		}
		after := f.settled(t)
		requireOneMoreRequest(t, before, after, cachefunnel.CancelledAfterDispatch, 1)
		if after.Total.SSDHitRequests != before.Total.SSDHitRequests || after.Late.Completions != before.Late.Completions {
			t.Fatalf("before %+v after %+v, want no hit and no late completion while the provider is still working", before, after)
		}
		// The provider finishes for a client that is gone. Its hit is billed and
		// feeds the per-completion counters; the closed request keeps its reason
		// and the funnel states the completion it did not fold in.
		close(release)
		awaitCondition(t, 5*time.Second, func() bool {
			return f.server.ExactCacheStatusSnapshot().Funnel.Late.Completions == before.Late.Completions+1
		}, "the completion after close counted as late")
		late := f.server.ExactCacheStatusSnapshot().Funnel
		if late.Closed != after.Closed || late.Total != after.Total {
			t.Fatalf("late completion changed the closed funnel: %+v -> %+v", after, late)
		}
		// The late hit is counted in the units of the counters it still feeds:
		// one SSD hit on the public status, its reuse on the admin metrics.
		if late.Late.SSDHitCompletions != before.Late.SSDHitCompletions+1 || late.Late.MemoryHitCompletions != before.Late.MemoryHitCompletions {
			t.Fatalf("late = %+v, want one more SSD hit completion than %+v", late.Late, before.Late)
		}
		f.awaitCounter(t, "exact_cache_funnel_late_reused_tokens_total{tier=ssd}", 256)
		f.awaitCounter(t, "exact_cache_funnel_late_prefill_saved_tokens_total{tier=ssd}", 256)
	})

	// The three requests reconcile across the counter families. Every accepted
	// SSD lookup receipt is a hit or a miss; the holders added minus those
	// removed are the holders recorded now; the receipt-level SSD hits are the
	// funnel's SSD hit requests plus the late SSD hit completions; and the
	// billed SSD reuse is the funnel's plus the late completion's.
	status := f.server.ExactCacheStatusSnapshot()
	lifecycle, funnel := status.Lifecycle, status.Funnel
	var removed uint64
	for _, count := range lifecycle.HolderRemoved {
		removed += count
	}
	if lifecycle.SSDLookups != lifecycle.SSDHits+lifecycle.SSDMisses || lifecycle.SSDMisses != 1 {
		t.Fatalf("lifecycle = %+v, want every SSD lookup a hit or the seed's one miss", lifecycle)
	}
	if int(lifecycle.HolderAdded-removed) != status.Holders {
		t.Fatalf("holders added %d - removed %d != %d holders", lifecycle.HolderAdded, removed, status.Holders)
	}
	if lifecycle.SSDHits != funnel.Total.SSDHitRequests+funnel.Late.SSDHitCompletions {
		t.Fatalf("lifecycle ssd_hits %d != funnel ssd_hit_requests %d + late ssd_hit_completions %d",
			lifecycle.SSDHits, funnel.Total.SSDHitRequests, funnel.Late.SSDHitCompletions)
	}
	counters := f.server.observation.Metrics().Snapshot().Counters
	billed, lateReused := counters["exact_cache_cached_tokens_total{tier=ssd}"], counters["exact_cache_funnel_late_reused_tokens_total{tier=ssd}"]
	if folded := counters["exact_cache_funnel_reused_tokens_total{reason=hit,tier=ssd}"]; billed != folded+lateReused || billed != 512 {
		t.Fatalf("billed ssd reuse %d != funnel %d + late %d", billed, folded, lateReused)
	}
}
