package api

import (
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// billing.cache_read_discount_micro_usd reports only a discount the consumer
// actually received: a request that settled at its computed price above the
// per-request minimum. Under the minimum the bill is the minimum either way,
// and an overage clamp settles at a cap the cold price would have hit too.
func TestCacheReadDiscountMetricCountsOnlySettledDiscounts(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	collector := newUDPCollector(t)
	defer collector.Close()
	dd := newTestDD(t, collector)
	defer dd.Close()
	srv.SetDatadog(dd)

	rates := payments.Rates{Input: 300_000, Output: 1_200_000, CacheRead: 30_000}
	for _, model := range []string{"disc-settled", "disc-minimum", "disc-clamped"} {
		cacheRead := rates.CacheRead
		if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: rates.Input, OutputPrice: rates.Output, CacheReadPrice: &cacheRead}); err != nil {
			t.Fatal(err)
		}
	}
	hit := cacheHitUsage()
	cold := rates.CostWithMinimum(payments.Usage{PromptTokens: hit.PromptTokens, CompletionTokens: hit.CompletionTokens})
	wantDiscount := payments.CacheReadDiscount(rates.CostWithMinimum, billableUsage(hit))
	if wantDiscount <= 0 {
		t.Fatalf("test setup: discount %d must be positive", wantDiscount)
	}

	// Settled at its computed price: the full discount counts.
	settleOnce(t, srv, ledger, "disc-prov-settled", "disc-settled", testConsumerID, cold, hit)

	// Cold and warm both under the 100 µUSD minimum: the bill is the minimum
	// either way, so no discount was given.
	tiny := protocol.UsageInfo{PromptTokens: 200, CompletionTokens: 10, CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 150, PrefillTokensSaved: 140, CacheStageMs: 1}
	if rates.Cost(billableUsage(tiny)) >= payments.MinimumCharge() || payments.CacheReadDiscount(rates.Cost, billableUsage(tiny)) == 0 {
		t.Fatal("test setup: tiny request must sit under the minimum with a per-token discount")
	}
	settleOnce(t, srv, ledger, "disc-prov-minimum", "disc-minimum", testConsumerID, payments.MinimumCharge(), tiny)

	// Reservation far below the cost: the overage clamp settles at 2× the
	// reservation, a cap the cold price hits as well.
	settleOnce(t, srv, ledger, "disc-prov-clamped", "disc-clamped", testConsumerID, 200, hit)

	_ = dd.Statsd.Flush()
	lines := findMetrics(collector.drain(), "billing.cache_read_discount_micro_usd")
	var settled []string
	for _, line := range lines {
		switch {
		case strings.Contains(line, "model:disc-settled"):
			settled = append(settled, line)
		case strings.Contains(line, "model:disc-minimum"), strings.Contains(line, "model:disc-clamped"):
			t.Errorf("discount metric emitted for a request that got no discount: %s", line)
		}
	}
	if len(settled) != 1 || !strings.Contains(settled[0], ":"+strconv.FormatInt(wantDiscount, 10)+"|c") {
		t.Fatalf("settled discount lines = %v, want one count of %d", settled, wantDiscount)
	}
}

// A request settled against a model-token grant is priced by priceModelTokens
// at the input rate for every prompt token, even on a cache hit, and records
// no cached tokens in usage history, whose cached_tokens means "billed at the
// cache-read rate".
func TestModelTokenPromotionBillsCachedPromptAtInputRate(t *testing.T) {
	s, st, r := promotionTestServer(t, 100)
	cacheRead := int64(100_000)
	if err := st.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: promoTestModel, InputPrice: 1_000_000, OutputPrice: 2_000_000, CacheReadPrice: &cacheRead}); err != nil {
		t.Fatal(err)
	}
	const seed int64 = 5_000
	if err := st.Credit("promotion-user", seed, store.LedgerAdminCredit, "seed"); err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	amount, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 1_000, requestedMaxTokens: 10})
	if handled || modelTokenReservation(r) == nil {
		t.Fatalf("admission handled=%v body=%s", handled, w.Body)
	}
	provider := s.registry.Register("promotion-cache-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: promoTestModel}}})
	provider.Mu().Lock()
	provider.AccountID = "paid-provider"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{RequestID: "promotion-cache-hit", Model: promoTestModel, PublicModel: promoTestModel, ConsumerKey: "promotion-user", ReservedMicroUSD: amount, EstimatedPromptTokens: 1_000, RequestedMaxTokens: 10, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	stampModelTokenReservation(pr, modelTokenReservation(r))
	provider.AddPending(pr)

	usage := protocol.UsageInfo{PromptTokens: 1_000, CompletionTokens: 10, CacheOutcome: "hit", CacheTier: "ssd", CachedTokens: 800, PrefillTokensSaved: 790, CacheStageMs: 3}
	s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage})

	// 100 free tokens cover the first 100 prompt tokens; the remaining 900
	// prompt tokens bill at the full $1.00/1M input rate despite 800 of them
	// being cache hits, plus 10 completion tokens at $2.00/1M.
	const want int64 = 900 + 20
	if got := seed - st.GetBalance("promotion-user"); got != want {
		t.Fatalf("consumer charged %d, want %d (cached prompt tokens at the input rate)", got, want)
	}
	entries := s.ledger.Usage("promotion-user")
	if len(entries) != 1 || entries[0].CachedTokens != 0 || entries[0].CostMicroUSD != want {
		t.Fatalf("usage entry = %+v, want cached=0 cost=%d", entries, want)
	}
	rows := awaitUsageRows(t, st, "promotion-user")
	if len(rows) != 1 || rows[0].CachedTokens != 0 || rows[0].PromptTokens != usage.PromptTokens {
		t.Fatalf("persisted usage = %+v, want one row with cached=0", rows)
	}
}
