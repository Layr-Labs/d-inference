package billing_test

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newConfigChangeQuote(t *testing.T, failFirst bool) (*billingFixture, *memory.MemoryStore, *store.User, *fakeGlobalStripe, string) {
	t.Helper()
	s, st, u, f := globalPayoutAPIFixture(t, failFirst)
	w := globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"IN"}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = globalAPIRequest(t, s, u, "/v1/billing/stripe/quote", `{"amount_usd":"10"}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	var q struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &q); err != nil {
		t.Fatal(err)
	}
	return s, st, u, f, q.ID
}

func TestGlobalPayoutFundingChangeRejectsUndebitedQuote(t *testing.T) {
	s, st, u, f, id := newConfigChangeQuote(t, false)
	s.Billing().GlobalPayouts().FinancialAccount = "fa_new"
	w := globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"10","quote_id":"`+id+`"}`)
	p, _ := st.GetGlobalPayout(id)
	if w.Code != 409 || !p.QuoteInvalidated || f.creates != 0 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatalf("changed quote debited: %d %+v", w.Code, p)
	}
}

func TestGlobalPayoutPauseExpiresUnsubmittedConfirmation(t *testing.T) {
	s, st, u, f, id := newConfigChangeQuote(t, false)
	base := s.Billing().GlobalPayouts().BaseURL
	s.SetBilling(billing.NewService(st, s.Billing().Ledger(), s.logger, billing.Config{MockMode: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp"}))
	s.Billing().GlobalPayouts().BaseURL = base
	w := globalAPIRequest(t, s, u, "/v1/billing/withdraw/stripe", `{"amount_usd":"10","quote_id":"`+id+`"}`)
	var result struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &result)
	p, _ := st.GetGlobalPayout(id)
	if w.Code != http.StatusConflict || result.Error.Code != "quote_paused" || !p.QuoteInvalidated || f.creates != 0 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatalf("paused confirmation stranded: %d %s", w.Code, w.Body.String())
	}
}
