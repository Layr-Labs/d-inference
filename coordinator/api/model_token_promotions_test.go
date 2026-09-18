package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const promoTestModel = "promotion-test-model"

func promotionTestServer(t *testing.T, tokens int64) (*Server, *store.MemoryStore, *http.Request) {
	t.Helper()
	s, st, _ := billingTestServer(t)
	t.Cleanup(s.Close)
	u := &store.User{AccountID: "promotion-user", PrivyUserID: "did:privy:promotion-user"}
	if err := st.CreateUser(u); err != nil {
		t.Fatal(err)
	}
	if err := st.PutModelTokenPromotion(store.ModelTokenPromotion{ModelID: promoTestModel, Tokens: tokens, ClaimStartsAt: time.Now().Add(-time.Hour), ClaimEndsAt: promotionClaimEnd(time.Now().Add(time.Hour)), SignupCutoffAt: time.Now().Add(time.Hour), MaxClaims: 250, Enabled: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.ClaimModelTokenPromotion(u.AccountID, promoTestModel, time.Now()); err != nil {
		t.Fatal(err)
	}
	ctx := context.WithValue(context.Background(), ctxKeyConsumer, u.AccountID)
	ctx = context.WithValue(ctx, auth.CtxKeyUser, u)
	r := withModelTokenRequest(httptest.NewRequest("POST", "/v1/chat/completions", nil).WithContext(ctx))
	// Exercise optional capability discovery through the production decorator.
	s.store = store.NewCached(st, store.CacheConfig{})
	return s, st, r
}

func TestModelTokenPromotionAdmissionAndComplete(t *testing.T) {
	s, st, r := promotionTestServer(t, 150_000_000)
	w := httptest.NewRecorder()
	amount, service, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 1000, estimatedPromptTokens: 250, requestedMaxTokens: 500})
	if handled || service || amount != 0 || modelTokenReservation(r) == nil {
		t.Fatalf("admission amount=%d service=%v handled=%v body=%s", amount, service, handled, w.Body)
	}
	provider := s.registry.Register("promotion-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: promoTestModel}}})
	provider.AccountID = "paid-provider"
	pr := &registry.PendingRequest{RequestID: "promotion-complete", Model: promoTestModel, PublicModel: promoTestModel, ConsumerKey: "promotion-user", EstimatedPromptTokens: 250, RequestedMaxTokens: 500, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	stampModelTokenReservation(pr, modelTokenReservation(r))
	if _, err := s.reserveAdditionalForProvider(pr, provider); err != nil {
		t.Fatal(err)
	}
	provider.AddPending(pr)
	usage := protocol.UsageInfo{PromptTokens: 200, CompletionTokens: 300}
	s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage})
	if got := st.GetBalance("promotion-user"); got != 0 {
		t.Fatal("consumer charged", got)
	}
	want := payments.ProviderPayout(payments.CalculateCost(promoTestModel, 200, 300))
	if got := st.GetWithdrawableBalance("paid-provider"); got != want {
		t.Fatalf("provider got %d want %d", got, want)
	}
	grants, _ := st.ListModelTokenGrants("promotion-user")
	if grants[0].UsedTokens != 500 || grants[0].ReservedTokens != 0 {
		t.Fatal(grants)
	}
	if usage := s.ledger.Usage("promotion-user"); len(usage) != 1 || usage[0].CostMicroUSD != 0 {
		t.Fatal(usage)
	}
	if s.refundReservedBalance(pr, "late-refund") {
		t.Fatal("settled promotion refunded")
	}
}

func TestModelTokenPromotionPartialPaidAndExhaustedAPIError(t *testing.T) {
	s, st, r := promotionTestServer(t, 100)
	if err := st.SetModelPrice("platform", promoTestModel, 1_000_000, 2_000_000); err != nil {
		t.Fatal(err)
	}
	if err := st.Credit("promotion-user", 1000, store.LedgerAdminCredit, "seed"); err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	amount, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 120, requestedMaxTokens: 100})
	if handled || amount != 220 {
		t.Fatalf("partial reservation %d %v %s", amount, handled, w.Body)
	}
	pr := &registry.PendingRequest{RequestID: "partial", Model: promoTestModel, ConsumerKey: "promotion-user", ReservedMicroUSD: amount}
	stampModelTokenReservation(pr, modelTokenReservation(r))
	provider := &registry.Provider{ID: "p", AccountID: "provider"}
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 10}
	ok, charged, err := s.settleModelTokenPromotion(pr, provider, usage, 1_000_000, 2_000_000, true, 120, false, nil)
	if err != nil || !ok || charged != 100 || st.GetBalance("promotion-user") != 900 || st.GetBalance("provider") != 120 {
		t.Fatalf("partial settlement ok=%v paid=%d err=%v", ok, charged, err)
	}
	if err := st.Debit("promotion-user", 900, store.LedgerCharge, "empty"); err != nil {
		t.Fatal(err)
	}
	r = withModelTokenRequest(r)
	w = httptest.NewRecorder()
	_, _, handled = s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 100, requestedMaxTokens: 10})
	if !handled || w.Code != 402 || !strings.Contains(w.Body.String(), "free_tokens_exhausted") {
		t.Fatalf("exhaustion response: %d %s", w.Code, w.Body)
	}
}

func TestModelTokenPromotionMediaTopUpAndRefund(t *testing.T) {
	s, st, r := promotionTestServer(t, 1_000_000)
	w := httptest.NewRecorder()
	p := balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 100, requestedMaxTokens: 100}
	amount, _, handled := s.reserveInferenceBalance(w, r, nil, p)
	if handled {
		t.Fatal(w.Body)
	}
	p.billingPromptTokens = 100_000
	amount, handled = s.topUpReservationForInlinedMedia(w, r, nil, p, amount)
	if handled || amount != 0 || modelTokenReservation(r).FreeTokens != 100_100 {
		t.Fatalf("media topup: %d %v %s", amount, handled, w.Body)
	}
	if !s.releaseModelTokenRequest(r) {
		t.Fatal("no grant refund")
	}
	if !s.releaseModelTokenRequest(r) {
		t.Fatal("promotion identity lost")
	}
	grants, _ := st.ListModelTokenGrants("promotion-user")
	if grants[0].RemainingTokens != 1_000_000 || st.GetBalance("promotion-user") != 0 {
		t.Fatal(grants)
	}
}

func TestModelTokenPromotionSelfRouteAndKeyLimit(t *testing.T) {
	s, st, r := promotionTestServer(t, 10_000)
	w := httptest.NewRecorder()
	_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, policy: selfRoutePolicy{enabled: true}, billingPromptTokens: 100, requestedMaxTokens: 100})
	if handled || modelTokenReservation(r) != nil {
		t.Fatal("exclusive self route consumed grant")
	}
	zero := int64(0)
	r = withModelTokenRequest(r.WithContext(context.WithValue(r.Context(), ctxKeyAPIKey, &store.APIKey{ID: "capped", LimitMicroUSD: &zero})))
	_, _, handled = s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 100, requestedMaxTokens: 100})
	if handled {
		t.Fatal("zero-dollar key should allow free requests", w.Body)
	}
	pr := &registry.PendingRequest{RequestID: "owned", Model: promoTestModel, ConsumerKey: "promotion-user"}
	stampModelTokenReservation(pr, modelTokenReservation(r))
	ok, paid, err := s.settleModelTokenPromotion(pr, &registry.Provider{AccountID: "promotion-user"}, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}, 0, 0, false, 0, true, nil)
	if err != nil || !ok || paid != 0 {
		t.Fatalf("owned completion: %v %d %v", ok, paid, err)
	}
	grants, _ := st.ListModelTokenGrants("promotion-user")
	if grants[0].UsedTokens != 0 || grants[0].RemainingTokens != 10_000 {
		t.Fatal("owned route spent grant", grants)
	}
}

func TestModelTokenPromotionRoutesRequireInteractiveClaimAndAdminMutation(t *testing.T) {
	s, _, r := promotionTestServer(t, 100)
	w := httptest.NewRecorder()
	r.Method = http.MethodGet
	s.handleMyModelTokenPromotions(w, r)
	var body struct {
		Grants []store.ModelTokenGrant `json:"grants"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil || len(body.Grants) != 1 {
		t.Fatalf("list: %s %v", w.Body, err)
	}
	for _, path := range []string{"/v1/me/token-promotions/claim", "/v1/admin/token-promotions"} {
		req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{}`))
		if strings.Contains(path, "admin") {
			req.Method = http.MethodPut
		}
		req.Header.Set("Authorization", "Bearer test-key")
		w = httptest.NewRecorder()
		s.Handler().ServeHTTP(w, req)
		if w.Code == http.StatusOK {
			t.Fatalf("unprivileged mutation accepted: %s", path)
		}
	}
}

func TestModelTokenPromotionCannotInflateProviderPriceOrPayOwnAccount(t *testing.T) {
	for _, owned := range []bool{false, true} {
		t.Run(map[bool]string{false: "platform_price", true: "own_account"}[owned], func(t *testing.T) {
			s, st, r := promotionTestServer(t, 10_000)
			account := "provider"
			if owned {
				account = "promotion-user"
			}
			if err := st.SetModelPrice(account, promoTestModel, 1_000_000_000, 1_000_000_000); err != nil {
				t.Fatal(err)
			}
			w := httptest.NewRecorder()
			_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 1000, requestedMaxTokens: 500})
			if handled {
				t.Fatal(w.Body)
			}
			provider := s.registry.Register("promotion-price-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: promoTestModel}}})
			provider.AccountID = account
			pr := &registry.PendingRequest{RequestID: "promotion-price", Model: promoTestModel, PublicModel: promoTestModel, ConsumerKey: "promotion-user", EstimatedPromptTokens: 1000, RequestedMaxTokens: 500, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
			stampModelTokenReservation(pr, modelTokenReservation(r))
			if amount, err := s.reserveAdditionalForProvider(pr, provider); err != nil || amount != 0 {
				t.Fatalf("custom price enlarged subsidy: %d %v", amount, err)
			}
			provider.AddPending(pr)
			s.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 200, CompletionTokens: 300}})
			want := payments.ProviderPayout(payments.CalculateCost(promoTestModel, 200, 300))
			used := int64(500)
			if owned {
				want = 0
				used = 0
			}
			if got := st.GetWithdrawableBalance(account); got != want {
				t.Fatalf("provider credit %d, want %d", got, want)
			}
			grants, _ := st.ListModelTokenGrants("promotion-user")
			if grants[0].UsedTokens != used || grants[0].ReservedTokens != 0 {
				t.Fatal(grants)
			}
		})
	}
}

func promotionClaimEnd(at time.Time) *time.Time { return &at }

type promotionLostCommitStore struct {
	store.Store
	store.ModelTokenPromotionStore
	lost bool
}

func (s *promotionLostCommitStore) SettleModelTokenReservation(id string, actual int64, quote store.ModelTokenQuote, earning *store.ProviderEarning) (store.ModelTokenSettlement, error) {
	result, err := s.ModelTokenPromotionStore.SettleModelTokenReservation(id, actual, quote, earning)
	if err == nil && !s.lost {
		s.lost = true
		return store.ModelTokenSettlement{}, errors.New("simulated lost commit acknowledgement")
	}
	return result, err
}

func TestModelTokenPromotionAmbiguousCommitReconcilesWithoutRefundOrDoublePayout(t *testing.T) {
	s, st, r := promotionTestServer(t, 10_000)
	w := httptest.NewRecorder()
	_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 1000, requestedMaxTokens: 100})
	if handled {
		t.Fatal(w.Body)
	}
	pr := &registry.PendingRequest{RequestID: "lost-commit", Model: promoTestModel, ConsumerKey: "promotion-user"}
	stampModelTokenReservation(pr, modelTokenReservation(r))
	s.store = &promotionLostCommitStore{Store: st, ModelTokenPromotionStore: st}
	_, _, err := s.settleModelTokenPromotion(pr, &registry.Provider{ID: "p", AccountID: "provider"}, protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}, 0, 0, false, 100, false, nil)
	if err == nil {
		t.Fatal("missing injected failure")
	}
	if s.refundReservedBalance(pr, "incorrect-refund") {
		t.Fatal("uncertain settlement refunded")
	}
	s.releaseModelTokenRequest(r)
	s.maintainModelTokens(st, time.Now())
	if _, pending := s.modelTokenSettlements.Load(pr.ModelTokenReservationID); pending {
		t.Fatal("settlement not reconciled")
	}
	grants, _ := st.ListModelTokenGrants("promotion-user")
	if grants[0].UsedTokens != 150 || grants[0].ReservedTokens != 0 {
		t.Fatal(grants)
	}
	if st.GetWithdrawableBalance("provider") != 100 || st.GetBalance("promotion-user") != 0 {
		t.Fatal("replay changed money twice")
	}
}

func TestModelTokenPromotionInvalidTerminalReleasesHoldInsteadOfRetryingForever(t *testing.T) {
	s, st, r := promotionTestServer(t, 10_000)
	w := httptest.NewRecorder()
	_, _, handled := s.reserveInferenceBalance(w, r, nil, balanceReservationParams{model: promoTestModel, publicModel: promoTestModel, billingPromptTokens: 100, requestedMaxTokens: 100})
	if handled {
		t.Fatal(w.Body)
	}
	pr := &registry.PendingRequest{RequestID: "bad-terminal", Model: promoTestModel, ConsumerKey: "promotion-user"}
	stampModelTokenReservation(pr, modelTokenReservation(r))
	_, _, err := s.settleModelTokenPromotion(pr, &registry.Provider{ID: "p", AccountID: "provider"}, protocol.UsageInfo{PromptTokens: 1_000_000_000, CompletionTokens: 1_000_000_000}, 0, 0, false, 1_000_000, false, nil)
	if !errors.Is(err, store.ErrPromotionInvalidSettlement) {
		t.Fatal(err)
	}
	if _, pending := s.modelTokenSettlements.Load(pr.ModelTokenReservationID); pending {
		t.Fatal("permanent error queued forever")
	}
	grants, _ := st.ListModelTokenGrants("promotion-user")
	if grants[0].RemainingTokens != 10_000 {
		t.Fatal(grants)
	}
	if st.GetBalance("provider") != 0 {
		t.Fatal("invalid terminal paid provider")
	}
}

func TestModelTokenPromotionListingDoesNotClaimAndPostRequiresSelectedModel(t *testing.T) {
	s, st, _ := promotionTestServer(t, 150_000_000)
	u := &store.User{AccountID: "manual-claimant", PrivyUserID: "did:privy:manual-claimant"}
	if err := st.CreateUser(u); err != nil {
		t.Fatal(err)
	}
	ctx := context.WithValue(context.Background(), auth.CtxKeyUser, u)
	w := httptest.NewRecorder()
	s.handleMyModelTokenPromotions(w, httptest.NewRequest("GET", "/v1/me/token-promotions", nil).WithContext(ctx))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"status":"available"`) {
		t.Fatalf("listing: %d %s", w.Code, w.Body)
	}
	grants, _ := st.ListModelTokenGrants(u.AccountID)
	if len(grants) != 0 {
		t.Fatal("GET allocated a grant")
	}
	w = httptest.NewRecorder()
	s.handleMyModelTokenPromotions(w, httptest.NewRequest("POST", "/claim", strings.NewReader(`{}`)).WithContext(ctx))
	if w.Code != 400 {
		t.Fatal("missing model accepted")
	}
	for range 2 {
		w = httptest.NewRecorder()
		s.handleMyModelTokenPromotions(w, httptest.NewRequest("POST", "/claim", strings.NewReader(`{"model_id":"`+promoTestModel+`"}`)).WithContext(ctx))
		if w.Code != 200 {
			t.Fatal(w.Body)
		}
	}
	promotions, _ := st.ListModelTokenPromotions()
	if promotions[0].ClaimedCount != 2 {
		t.Fatalf("duplicate allocated slots: %+v", promotions)
	}
}
