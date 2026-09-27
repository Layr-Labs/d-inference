package api

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func newConfigChangeQuote(t *testing.T, failFirst bool) (*Server, *store.MemoryStore, *store.User, *fakeGlobalStripe, string) {
	t.Helper()
	s, st, u, f := globalPayoutAPIFixture(t, failFirst)
	w := globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.handleStripeOnboard)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
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

func TestGlobalPayoutFundingChangeReconcilesKnownReturn(t *testing.T) {
	s, st, u, f, id := newConfigChangeQuote(t, false)
	globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.handleStripeWithdraw)
	s.billing.GlobalPayouts().FinancialAccount = "fa_new"
	f.mu.Lock()
	f.state = "returned"
	f.mu.Unlock()
	for range 2 {
		if err := s.syncGlobalPayout(context.Background(), id); err != nil {
			t.Fatal(err)
		}
	}
	p, _ := st.GetGlobalPayout(id)
	if !p.Refunded || f.creates != 1 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatalf("old funding account return stranded: %+v", p)
	}
}

func TestGlobalPayoutFundingChangeRejectsUndebitedQuote(t *testing.T) {
	s, st, u, f, id := newConfigChangeQuote(t, false)
	s.billing.GlobalPayouts().FinancialAccount = "fa_new"
	w := globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.handleStripeWithdraw)
	p, _ := st.GetGlobalPayout(id)
	if w.Code != 409 || !p.QuoteInvalidated || f.creates != 0 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatalf("changed quote debited: %d %+v", w.Code, p)
	}
}

func TestGlobalPayoutFundingChangeRefundsOnlyFirstUnsentAttempt(t *testing.T) {
	for _, ambiguous := range []bool{false, true} {
		t.Run(map[bool]string{false: "never-sent", true: "ambiguous"}[ambiguous], func(t *testing.T) {
			s, st, u, f, id := newConfigChangeQuote(t, ambiguous)
			if ambiguous {
				globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.handleStripeWithdraw)
			} else {
				if _, err := st.BeginGlobalPayout(u.AccountID, id, time.Now()); err != nil {
					t.Fatal(err)
				}
			}
			s.billing.GlobalPayouts().FinancialAccount = "fa_new"
			if err := s.syncGlobalPayout(context.Background(), id); err != nil {
				t.Fatal(err)
			}
			p, _ := st.GetGlobalPayout(id)
			if ambiguous {
				if p.Refunded || f.creates != 1 || st.GetWithdrawableBalance(u.AccountID) != 10_000_000 {
					t.Fatalf("unknown payment refunded: %+v", p)
				}
			} else {
				if !p.Refunded || f.creates != 0 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
					t.Fatalf("unsent payment stranded: %+v", p)
				}
			}
		})
	}
}

func TestGlobalPayoutPauseExpiresUnsubmittedConfirmation(t *testing.T) {
	s, st, u, f, id := newConfigChangeQuote(t, false)
	base := s.billing.GlobalPayouts().BaseURL
	s.SetBilling(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{MockMode: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp"}))
	s.billing.GlobalPayouts().BaseURL = base
	w := globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.handleStripeWithdraw)
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
