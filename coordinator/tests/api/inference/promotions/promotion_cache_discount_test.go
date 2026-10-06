package inference_test

import (
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// A request settled against a model-token grant is priced by promotions.PriceTokens
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
	amount, _, handled := s.reservations.Reserve(w, r, nil, reservations.Params{Model: promoTestModel, PublicModel: promoTestModel, BillingPromptTokens: 1_000, RequestedMaxTokens: 10})
	if handled || promotions.Reservation(r) == nil {
		t.Fatalf("admission handled=%v body=%s", handled, w.Body)
	}
	provider := s.registry.Register("promotion-cache-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: promoTestModel}}})
	provider.Mu().Lock()
	provider.AccountID = "paid-provider"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{RequestID: "promotion-cache-hit", Model: promoTestModel, PublicModel: promoTestModel, ConsumerKey: "promotion-user", ReservedMicroUSD: amount, EstimatedPromptTokens: 1_000, RequestedMaxTokens: 10, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	promotions.StampReservation(pr, promotions.Reservation(r))
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
