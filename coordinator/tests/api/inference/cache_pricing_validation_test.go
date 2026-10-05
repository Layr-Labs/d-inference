package inference_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestSettlementFreeCacheReadPrice(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-free-model"
	zero := int64(0)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000, CacheReadPrice: &zero}); err != nil {
		t.Fatal(err)
	}
	usage := cacheHitUsage()
	const want int64 = 600 + 0 + 600
	initial := settleOnce(t, srv, ledger, "free-prov", model, testConsumerID, 10_000, usage)
	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d", got, initial-want)
	}
}

func TestSettlementIgnoresInvalidCacheUsage(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model = "cache-invalid-model"
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 300_000, OutputPrice: 1_200_000}); err != nil {
		t.Fatal(err)
	}
	usage := cacheHitUsage()
	usage.CachedTokens = usage.PromptTokens + 1
	usage.PrefillTokensSaved = usage.CachedTokens
	want := payments.Rates{Input: 300_000, Output: 1_200_000}.CostWithMinimum(payments.Usage{PromptTokens: usage.PromptTokens, CompletionTokens: usage.CompletionTokens})

	initial := settleOnce(t, srv, ledger, "invalid-prov", model, testConsumerID, 10_000, usage)
	if got := ledger.Balance(testConsumerID); got != initial-want {
		t.Fatalf("consumer balance = %d, want %d (full input price, no cache discount)", got, initial-want)
	}
	if entries := ledger.Usage(testConsumerID); len(entries) != 1 || entries[0].CachedTokens != 0 {
		t.Fatalf("usage entries = %+v, want one entry with cached_tokens 0", entries)
	}
}
