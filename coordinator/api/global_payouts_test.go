package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type fakeGlobalStripe struct {
	mu             sync.Mutex
	payments       map[string]globalpayouts.Payment
	creates        int
	failFirst      bool
	state          string
	rejectRequests bool
	bankStatus     int
	emptyBanks     bool
}

func (f *fakeGlobalStripe) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case r.URL.Path == "/v2/core/accounts" || strings.HasPrefix(r.URL.Path, "/v2/core/accounts/"):
		_, _ = w.Write([]byte(`{"id":"acct_gp","identity":{"country":"in"},"defaults":{"payout_methods":{"inr":"pm_gp"}},"configuration":{"recipient":{"capabilities":{"bank_accounts":{"local":{"status":"active"}}}}}}`))
	case r.URL.Path == "/v2/core/account_links":
		_, _ = w.Write([]byte(`{"url":"https://accounts.stripe.com/test-onboarding"}`))
	case r.URL.Path == "/v2/money_management/payout_methods":
		if f.bankStatus != 0 {
			w.WriteHeader(f.bankStatus)
			_, _ = w.Write([]byte(`{"error":{"code":"api_error"}}`))
			return
		}
		if f.emptyBanks {
			_, _ = w.Write([]byte(`{"data":[]}`))
			return
		}
		_, _ = w.Write([]byte(`{"data":[{"id":"pm_gp","type":"bank_account","bank_account":{"country":"IN","last4":"1234","supported_currencies":["inr"],"enabled_delivery_options":["local"]},"usage_status":{"payments":"eligible"}}]}`))
	case r.URL.Path == "/v2/money_management/outbound_payment_quotes":
		var req globalpayouts.PaymentRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		q := globalpayouts.Quote{ID: "obpq_gp", Amount: req.Amount, From: globalpayouts.Source{FinancialAccount: req.From["financial_account"], Debited: req.Amount}, To: globalpayouts.Destination{Recipient: req.To["recipient"], PayoutMethod: req.To["payout_method"], Credited: globalpayouts.Amount{Value: req.Amount.Value * 80, Currency: "inr"}}}
		_ = json.NewEncoder(w).Encode(q)
	case r.URL.Path == "/v2/money_management/outbound_payments":
		if f.rejectRequests {
			w.WriteHeader(403)
			_, _ = w.Write([]byte(`{"error":{"code":"forbidden"}}`))
			return
		}
		key := r.Header.Get("Idempotency-Key")
		p, ok := f.payments[key]
		if !ok {
			var req globalpayouts.PaymentRequest
			_ = json.NewDecoder(r.Body).Decode(&req)
			p = globalpayouts.Payment{ID: "obp_gp", Amount: req.Amount, From: globalpayouts.Source{FinancialAccount: req.From["financial_account"], Debited: req.Amount}, To: globalpayouts.Destination{Recipient: req.To["recipient"], PayoutMethod: req.To["payout_method"], Credited: globalpayouts.Amount{Value: req.Amount.Value * 80, Currency: "inr"}}, Status: "processing"}
			f.payments[key] = p
			f.creates++
			if f.failFirst {
				w.WriteHeader(503)
				_, _ = w.Write([]byte(`{"error":{"code":"response_lost"}}`))
				return
			}
		}
		_ = json.NewEncoder(w).Encode(p)
	case strings.HasPrefix(r.URL.Path, "/v2/money_management/outbound_payments/"):
		for _, p := range f.payments {
			p.Status = f.state
			_ = json.NewEncoder(w).Encode(p)
			return
		}
		w.WriteHeader(404)
	default:
		w.WriteHeader(404)
	}
}

func globalPayoutAPIFixture(t *testing.T, failFirst bool) (*Server, *store.MemoryStore, *store.User, *fakeGlobalStripe) {
	t.Helper()
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetBilling(billing.NewService(st, srv.billing.Ledger(), srv.logger, billing.Config{MockMode: true, StripeConnectReturnURL: "https://app.test/billing", StripeGlobalPayoutsEnabled: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp", StripeGlobalPayoutsWebhookSecret: "whsec_test"}))
	f := &fakeGlobalStripe{payments: map[string]globalpayouts.Payment{}, failFirst: failFirst, state: "posted"}
	remote := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(remote.Close)
	srv.billing.GlobalPayouts().BaseURL = remote.URL
	u := seedUser(t, st, "gp-account", "provider@example.com")
	if err := st.CreditWithdrawable(u.AccountID, 20_000_000, store.LedgerPayout, "earned"); err != nil {
		t.Fatal(err)
	}
	return srv, st, u, f
}
func globalAPIRequest(t *testing.T, s *Server, u *store.User, path, body string, handler http.HandlerFunc) *httptest.ResponseRecorder {
	t.Helper()
	req := withPrivyUser(httptest.NewRequest(http.MethodPost, path, strings.NewReader(body)), u)
	w := httptest.NewRecorder()
	handler(w, req)
	return w
}

func TestGlobalPayoutOnboardQuoteConfirmAndReturn(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, true)
	w := globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.handleStripeOnboard)
	if w.Code != 200 {
		t.Fatalf("onboard %d %s", w.Code, w.Body.String())
	}
	local, _ := st.GetGlobalRecipient(u.AccountID)
	if local.RecipientID != "acct_gp" {
		t.Fatalf("recipient: %+v", local)
	}
	w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10.00"}`, s.handleGlobalPayoutQuote)
	if w.Code != 200 {
		t.Fatalf("quote %d %s", w.Code, w.Body.String())
	}
	var quote struct {
		ID                string `json:"id"`
		DestinationAmount int64  `json:"destination_amount"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &quote)
	if quote.DestinationAmount != 80000 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatal("quote moved funds or returned wrong currency amount")
	}
	body := `{"amount_usd":"10.00","method":"standard","quote_id":"` + quote.ID + `"}`
	w = globalAPIRequest(t, s, u, "/withdraw", body, s.handleStripeWithdraw)
	if w.Code != 202 {
		t.Fatalf("confirm %d %s", w.Code, w.Body.String())
	}
	p, _ := st.GetGlobalPayout(quote.ID)
	if p.Status != "pending" || p.Refunded {
		t.Fatalf("ambiguous send was refunded: %+v", p)
	}
	// Retry even after unlink must remain a Global Payouts confirmation.
	if err := st.RemoveGlobalRecipient(u.AccountID); err != nil {
		t.Fatal(err)
	}
	w = globalAPIRequest(t, s, u, "/withdraw", body, s.handleStripeWithdraw)
	if w.Code != 202 {
		t.Fatalf("retry %d %s", w.Code, w.Body.String())
	}
	if f.creates != 1 || st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
		t.Fatal("retry duplicated money movement")
	}
	p, _ = st.GetGlobalPayout(quote.ID)
	if p.ExternalID != "obp_gp" {
		t.Fatal("retry lost payout ID")
	}
	if err := s.syncGlobalPayout(httptest.NewRequest("GET", "/", nil).Context(), p.ID); err != nil {
		t.Fatal(err)
	}
	p, _ = st.GetGlobalPayout(quote.ID)
	if p.Status != "posted" {
		t.Fatalf("status %s", p.Status)
	}
	f.state = "returned"
	for range 2 {
		if err := s.syncGlobalPayout(httptest.NewRequest("GET", "/", nil).Context(), p.ID); err != nil {
			t.Fatal(err)
		}
	}
	if st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatal("bank return failed to refund exactly once")
	}
}

func TestGlobalPayoutRejectsInvalidQuotesAndCountries(t *testing.T) {
	s, st, u, _ := globalPayoutAPIFixture(t, false)
	for _, country := range []string{"CN", "KH", "GI"} {
		w := globalAPIRequest(t, s, u, "/onboard", `{"country":"`+country+`"}`, s.handleStripeOnboard)
		if w.Code != 400 {
			t.Fatalf("unverified country %s accepted", country)
		}
	}
	for _, value := range []string{"NaN", "Inf", "1e4", "1.001", "-5", "0.99", "1000001"} {
		if _, err := payoutUSDCents(value); err == nil {
			t.Fatalf("invalid amount accepted %q", value)
		}
	}
	if st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatal("invalid requests moved funds")
	}
}

func TestGlobalPayoutUnknownOutcomeStopsResubmitting(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	r := store.GlobalRecipient{ID: "old", AccountID: u.AccountID, Country: "IN", RecipientID: "acct_gp", PayoutMethodID: "pm_gp", Ready: true}
	_, _ = st.PrepareGlobalRecipient(r)
	request := globalpayouts.NewRequest("fa_gp", "acct_gp", "pm_gp", "inr", 1000)
	data, _ := json.Marshal(request)
	p := store.GlobalPayout{ID: "old-quote", AccountID: u.AccountID, RecipientGeneration: r.ID, RecipientID: r.RecipientID, PayoutMethodID: r.PayoutMethodID, AmountMicroUSD: 10_000_000, Request: data, Status: "quoted", ExpiresAt: time.Now().Add(time.Minute)}
	if err := st.CreateGlobalPayoutQuote(p); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginGlobalPayout(u.AccountID, p.ID, time.Now().Add(-13*time.Hour)); err != nil {
		t.Fatal(err)
	}
	if err := s.syncGlobalPayout(httptest.NewRequest("GET", "/", nil).Context(), p.ID); err != nil {
		t.Fatal(err)
	}
	if f.creates != 0 || st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
		t.Fatal("old unknown outcome was resent or refunded")
	}
}

func TestGlobalPayoutAmbiguousSendThenPermissionLossDoesNotRefund(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, true)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.handleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	var q struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &q)
	body := `{"amount_usd":"10","quote_id":"` + q.ID + `"}`
	globalAPIRequest(t, s, u, "/withdraw", body, s.handleStripeWithdraw)
	f.mu.Lock()
	f.rejectRequests = true
	f.mu.Unlock()
	globalAPIRequest(t, s, u, "/withdraw", body, s.handleStripeWithdraw)
	p, _ := st.GetGlobalPayout(q.ID)
	if p.Refunded || p.Status != "pending" || st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
		t.Fatalf("permission loss refunded an already accepted payout: %+v", p)
	}
}

func TestGlobalPayoutPausePreservesReconciliation(t *testing.T) {
	s, st, u, _ := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.handleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	var q struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &q)
	if _, err := st.BeginGlobalPayout(u.AccountID, q.ID, time.Now()); err != nil {
		t.Fatal(err)
	}
	baseURL := s.billing.GlobalPayouts().BaseURL
	s.SetBilling(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{MockMode: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp", StripeGlobalPayoutsWebhookSecret: "whsec_test"}))
	s.billing.GlobalPayouts().BaseURL = baseURL
	w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	if w.Code != http.StatusBadGateway {
		t.Fatalf("new quote accepted while paused: %d", w.Code)
	}
	if err := s.syncGlobalPayout(httptest.NewRequest("GET", "/", nil).Context(), q.ID); err != nil {
		t.Fatal(err)
	}
	p, _ := st.GetGlobalPayout(q.ID)
	if p.ExternalID == "" || p.Status != "processing" {
		t.Fatalf("paused confirmed payment was stranded: %+v", p)
	}
}

func TestGlobalPayoutWebhookUsesCurrentStateAndSignature(t *testing.T) {
	s, st, u, _ := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.handleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	var q struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &q)
	globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+q.ID+`"}`, s.handleStripeWithdraw)
	payload := []byte(`{"type":"v2.money_management.outbound_payment.returned","related_object":{"id":"obp_gp"}}`)
	unsigned := httptest.NewRecorder()
	s.handleGlobalPayoutWebhook(unsigned, httptest.NewRequest("POST", "/", strings.NewReader(string(payload))))
	if unsigned.Code != 400 {
		t.Fatalf("unsigned event accepted: %d", unsigned.Code)
	}
	signed := httptest.NewRecorder()
	s.handleGlobalPayoutWebhook(signed, signedConnectRequest(t, payload, "whsec_test"))
	if signed.Code != 200 {
		t.Fatalf("signed event %d %s", signed.Code, signed.Body.String())
	}
	p, _ := st.GetGlobalPayout(q.ID)
	if p.Refunded || p.Status != "posted" {
		t.Fatalf("webhook state was trusted instead of current Stripe state: %+v", p)
	}
}
