package inference

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// cacheHitUsage is a valid provider cache report: 8,000 of 10,000 prompt tokens
// served from the SSD prefix cache.
func cacheHitUsage() protocol.UsageInfo {
	return protocol.UsageInfo{
		PromptTokens:       10_000,
		CompletionTokens:   500,
		CacheOutcome:       "hit",
		CacheTier:          "ssd",
		CachedTokens:       8_000,
		PrefillTokensSaved: 7_900,
		CacheStageMs:       12.5,
	}
}

// settleOnce registers a provider for model, reserves `reserve` for the test
// consumer and settles one completion carrying usage. Returns the consumer's
// balance before the reservation.
func settleOnce(t *testing.T, srv *Owner, ledger *payments.Ledger, providerID, model, consumerID string, reserve int64, usage protocol.UsageInfo) (initial int64) {
	t.Helper()
	provider := srv.registry.Register(providerID, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	initial = ledger.Balance(consumerID)
	if err := ledger.Charge(consumerID, reserve, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}
	pr := &registry.PendingRequest{
		RequestID:        "req-" + providerID,
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reserve,
		ChunkCh:          make(chan registry.ProviderChunk, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.HandleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	}, time.Now())
	return initial
}

// A valid cache hit bills the cached prefix at the platform row's explicit
// cache_read_price and the rest of the prompt at the input price; the
// difference to the worst-case reservation is refunded and the usage history
// records the cached count so the bill can be reconciled.
func TestSettlementBillsCachedTokensAtCacheReadRate(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-priced-model"
	cacheRead := int64(30_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &cacheRead}); err != nil {
		t.Fatal(err)
	}

	usage := cacheHitUsage()
	// 2,000 uncached × $0.30/1M + 8,000 cached × $0.03/1M + 500 × $1.20/1M.
	const want int64 = 600 + 240 + 600
	if got := (payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: cacheRead}).CostWithMinimum(billableUsage(usage)); got != want {
		t.Fatalf("test arithmetic: cost = %d, want %d", got, want)
	}
	cold := payments.Rates{Input: 300_000, Output: 1_200_000}.CostWithMinimum(payments.Usage{PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens})
	if cold <= want {
		t.Fatalf("test setup: cold cost %d must exceed cached cost %d", cold, want)
	}

	initial := settleOnce(t, srv, ledger, "cache-prov", model, testConsumerID, cold, usage)

	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d (debit %d, refund of %d from the reservation)", got, initial-want, want, cold-want)
	}
	entries := ledger.Usage(testConsumerID)
	if len(entries) != 1 {
		t.Fatalf("usage entries = %d, want 1", len(entries))
	}
	if entries[0].CachedTokens != usage.CachedTokens || entries[0].PromptTokens != usage.PromptTokens || entries[0].CostMicroUSD != want {
		t.Fatalf("usage entry = %+v, want cached=%d prompt=%d cost=%d", entries[0], usage.CachedTokens, usage.PromptTokens, want)
	}
	rows := awaitUsageRows(t, st, testConsumerID)
	if len(rows) != 1 || rows[0].CachedTokens != usage.CachedTokens || rows[0].CostMicroUSD != want {
		t.Fatalf("persisted usage = %+v, want one row with cached=%d cost=%d", rows, usage.CachedTokens, want)
	}
}

// awaitUsageRows waits for the settlement's asynchronous usage insert
// (saferun.Go in handleCompleteAt) and returns the consumer's rows.
func awaitUsageRows(t *testing.T, st *memory.MemoryStore, consumerID string) []store.UsageRecord {
	t.Helper()
	if !waitForCond(5*time.Second, func() bool { return len(st.UsageByConsumer(consumerID)) > 0 }) {
		t.Fatal("usage row was not persisted")
	}
	return st.UsageByConsumer(consumerID)
}

// A platform row without an explicit cache_read_price bills cached tokens at
// the derived default discount off its own input price.
func TestSettlementDerivesCacheReadDiscountWhenUnset(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-derived-model"
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000}); err != nil {
		t.Fatal(err)
	}
	usage := cacheHitUsage()
	want := payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: payments.DefaultCacheReadPrice(300_000)}.CostWithMinimum(billableUsage(usage))
	// 2,000 × 0.30 + 8,000 × 0.15 + 500 × 1.20 per 1M.
	if want != 600+1_200+600 {
		t.Fatalf("test arithmetic: want = %d", want)
	}

	initial := settleOnce(t, srv, ledger, "derived-prov", model, testConsumerID, 10_000, usage)
	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d", got, initial-want)
	}
}

// A provider's own price row carries its own cache-read rate for direct
// consumers (price resolution order: provider custom → platform).
func TestSettlementUsesProviderCustomCacheReadPrice(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-provider-price-model"
	const account = "cache-provider-account"
	platformCache := int64(10_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &platformCache}); err != nil {
		t.Fatal(err)
	}
	providerCache := int64(100_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: account, Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &providerCache}); err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("custom-cache-prov", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = account
	provider.Mu().Unlock()

	usage := cacheHitUsage()
	want := payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: providerCache}.CostWithMinimum(billableUsage(usage))
	initial := ledger.Balance(testConsumerID)
	const reserve int64 = 10_000
	if err := ledger.Charge(testConsumerID, reserve, "reserve:"+testConsumerID); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{
		RequestID: "custom-cache-req", Model: model, ConsumerKey: testConsumerID, ReservedMicroUSD: reserve,
		ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage})

	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d (provider cache-read rate %d, not platform %d)", got, initial-want, providerCache, platformCache)
	}
	if got := st.GetWithdrawableBalance(account); got != payments.ProviderPayout(want) {
		t.Fatalf("provider payout = %d, want %d", got, payments.ProviderPayout(want))
	}
}
