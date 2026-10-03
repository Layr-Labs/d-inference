package api

import (
	"encoding/json"
	"net/http"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newConfigChangeQuote(t *testing.T, failFirst bool) (*Server, *memory.MemoryStore, *store.User, *fakeGlobalStripe, string) {
	t.Helper()
	s, st, u, f := globalPayoutAPIFixture(t, failFirst)
	w := globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.payouts.HandleStripeOnboard)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.payouts.HandleGlobalPayoutQuote)
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
	s.billing.GlobalPayouts().FinancialAccount = "fa_new"
	w := globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.payouts.HandleStripeWithdraw)
	p, _ := st.GetGlobalPayout(id)
	if w.Code != 409 || !p.QuoteInvalidated || f.creates != 0 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatalf("changed quote debited: %d %+v", w.Code, p)
	}
}

func TestGlobalPayoutPauseExpiresUnsubmittedConfirmation(t *testing.T) {
	s, st, u, f, id := newConfigChangeQuote(t, false)
	base := s.billing.GlobalPayouts().BaseURL
	s.SetBilling(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{MockMode: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp"}))
	s.billing.GlobalPayouts().BaseURL = base
	w := globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.payouts.HandleStripeWithdraw)
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
