package billing_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type fakeGlobalStripe struct {
	mu                            sync.Mutex
	payments                      map[string]globalpayouts.Payment
	creates                       int
	failFirst                     bool
	state                         string
	rejectRequests                bool
	bankStatus                    int
	emptyBanks                    bool
	country, currency, quoteError string
	rate                          int64
	quoteCalls                    int
}

func (f *fakeGlobalStripe) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case strings.HasPrefix(r.URL.Path, "/v2/money_management/financial_accounts/"):
		_ = json.NewEncoder(w).Encode(map[string]any{"id": strings.TrimPrefix(r.URL.Path, "/v2/money_management/financial_accounts/"), "status": "open", "balance": map[string]any{"available": map[string]any{"usd": globalpayouts.Amount{Value: 100_000_000, Currency: "usd"}}}})

	case r.URL.Path == "/v2/core/accounts" || strings.HasPrefix(r.URL.Path, "/v2/core/accounts/"):
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "acct_gp", "identity": map[string]string{"country": f.country}, "defaults": map[string]any{"payout_methods": map[string]string{f.currency: "pm_gp"}}, "configuration": map[string]any{"recipient": map[string]any{"capabilities": map[string]any{"bank_accounts": map[string]any{"local": map[string]string{"status": "active"}, "wire": map[string]string{"status": "active"}}}}}})
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
		m := globalpayouts.BankMethod{ID: "pm_gp", Type: "bank_account"}
		m.BankAccount.Country = strings.ToUpper(f.country)
		m.BankAccount.Last4 = "1234"
		m.BankAccount.SupportedCurrencies = []string{f.currency}
		m.BankAccount.EnabledDeliveryOptions = []string{"local", "wire"}
		m.UsageStatus.Payments = "eligible"
		_ = json.NewEncoder(w).Encode(map[string]any{"data": []globalpayouts.BankMethod{m}})
	case r.URL.Path == "/v2/money_management/outbound_payment_quotes":
		f.quoteCalls++
		if f.quoteError != "" {
			w.WriteHeader(400)
			_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": f.quoteError}})
			return
		}
		var req globalpayouts.PaymentRequest
		_ = json.NewDecoder(r.Body).Decode(&req)
		q := globalpayouts.Quote{EstimatedFees: []globalpayouts.EstimatedFee{{Type: "standard_payout_fee", Amount: globalpayouts.EstimatedFeeAmount{Currency: "usd", Value: json.Number("150")}}}, ID: "obpq_gp", Amount: req.Amount, From: globalpayouts.Source{FinancialAccount: req.From["financial_account"], Debited: req.Amount}, To: globalpayouts.Destination{Recipient: req.To["recipient"], PayoutMethod: req.To["payout_method"], Credited: globalpayouts.Amount{Value: req.Amount.Value * f.rate, Currency: f.currency}}}
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
			p = globalpayouts.Payment{ID: "obp_gp", Amount: req.Amount, From: globalpayouts.Source{FinancialAccount: req.From["financial_account"], Debited: req.Amount}, To: globalpayouts.Destination{Recipient: req.To["recipient"], PayoutMethod: req.To["payout_method"], Credited: globalpayouts.Amount{Value: req.Amount.Value * f.rate, Currency: f.currency}}, Status: "processing"}
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

func globalPayoutAPIFixture(t *testing.T, failFirst bool) (*billingFixture, *memory.MemoryStore, *store.User, *fakeGlobalStripe) {
	t.Helper()
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetBilling(billing.NewService(st, srv.Billing().Ledger(), srv.logger, billing.Config{MockMode: true, StripeConnectReturnURL: "https://app.test/billing", StripeGlobalPayoutsEnabled: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp", StripeGlobalPayoutsWebhookSecret: "whsec_test"}))
	f := &fakeGlobalStripe{payments: map[string]globalpayouts.Payment{}, failFirst: failFirst, state: "posted", country: "in", currency: "inr", rate: 80}
	remote := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(remote.Close)
	srv.Billing().GlobalPayouts().BaseURL = remote.URL
	u := seedUser(t, st, "gp-account", "provider@example.com")
	if err := st.CreditWithdrawable(u.AccountID, 20_000_000, store.LedgerPayout, "earned"); err != nil {
		t.Fatal(err)
	}
	return srv, st, u, f
}
func globalAPIRequest(t *testing.T, s *billingFixture, u *store.User, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	method := http.MethodPost
	if strings.HasPrefix(path, "/v1/billing/stripe/status") {
		method = http.MethodGet
	}
	req := s.withUser(httptest.NewRequest(method, path, strings.NewReader(body)), u)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, req)
	return w
}

func TestGlobalPayoutAmbiguousSendThenPermissionLossDoesNotRefund(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, true)
	globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"IN"}`)
	w := globalAPIRequest(t, s, u, "/v1/billing/stripe/quote", `{"amount_usd":"10"}`)
	var q struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &q)
	body := `{"amount_usd":"10","quote_id":"` + q.ID + `"}`
	globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", body)
	f.mu.Lock()
	f.rejectRequests = true
	f.mu.Unlock()
	globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", body)
	p, _ := st.GetGlobalPayout(q.ID)
	if p.Refunded || p.Status != "pending" || st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
		t.Fatalf("permission loss refunded an already accepted payout: %+v", p)
	}
}

func TestGlobalPayoutWebhookUsesCurrentStateAndSignature(t *testing.T) {
	s, st, u, _ := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"IN"}`)
	w := globalAPIRequest(t, s, u, "/v1/billing/stripe/quote", `{"amount_usd":"10"}`)
	var q struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &q)
	globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"10","quote_id":"`+q.ID+`"}`)
	payload := []byte(`{"type":"v2.money_management.outbound_payment.returned","related_object":{"id":"obp_gp"}}`)
	unsigned := httptest.NewRecorder()
	s.Handler().ServeHTTP(unsigned, httptest.NewRequest("POST", "/v1/billing/stripe/global/webhook", strings.NewReader(string(payload))))
	if unsigned.Code != 400 {
		t.Fatalf("unsigned event accepted: %d", unsigned.Code)
	}
	signed := httptest.NewRecorder()
	s.Handler().ServeHTTP(signed, signedStripeRequest(t, payload, "whsec_test", "/v1/billing/stripe/global/webhook"))
	if signed.Code != 200 {
		t.Fatalf("signed event %d %s", signed.Code, signed.Body.String())
	}
	p, _ := st.GetGlobalPayout(q.ID)
	if p.Refunded || p.Status != "posted" {
		t.Fatalf("webhook state was trusted instead of current Stripe state: %+v", p)
	}
}
