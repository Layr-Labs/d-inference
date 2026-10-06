package payouts_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func newConfigChangeQuote(t *testing.T, failFirst bool) (*payoutFixture, *memory.MemoryStore, *store.User, *fakeGlobalStripe, string) {
	t.Helper()
	s, st, u, f := globalPayoutAPIFixture(t, failFirst)
	w := globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.HandleStripeOnboard)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.HandleGlobalPayoutQuote)
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
	globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.HandleStripeWithdraw)
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

func TestGlobalPayoutFundingChangeRefundsOnlyFirstUnsentAttempt(t *testing.T) {
	for _, ambiguous := range []bool{false, true} {
		t.Run(map[bool]string{false: "never-sent", true: "ambiguous"}[ambiguous], func(t *testing.T) {
			s, st, u, f, id := newConfigChangeQuote(t, ambiguous)
			if ambiguous {
				globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+id+`"}`, s.HandleStripeWithdraw)
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
