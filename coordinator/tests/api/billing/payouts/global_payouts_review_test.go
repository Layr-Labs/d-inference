package payouts_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestGlobalPayoutDisabledPreservesLegacyConnect(t *testing.T) {
	for _, country := range []string{"AU", "IN", "JP", "BR", "GH", "NG"} {
		t.Run(country, func(t *testing.T) {
			s, st, u, _ := globalPayoutAPIFixture(t, false)
			s.SetService(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{MockMode: true, StripeConnectReturnURL: "https://app.test/billing", StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp"}))
			if s.billing.GlobalPayouts() == nil {
				t.Fatal("test must configure the disabled client")
			}
			status := globalAPIRequest(t, s, u, "/status", "", s.HandleStripeStatus)
			var statusBody struct {
				Countries []any `json:"countries"`
			}
			if status.Code != 200 || json.Unmarshal(status.Body.Bytes(), &statusBody) != nil {
				t.Fatalf("invalid payout status: %d %s", status.Code, status.Body.String())
			}
			if statusBody.Countries != nil {
				t.Fatal("disabled flag replaced the legacy country menu")
			}
			w := globalAPIRequest(t, s, u, "/onboard", `{"country":"`+country+`"}`, s.HandleStripeOnboard)
			if w.Code != 200 {
				t.Fatalf("legacy onboarding rejected: %d %s", w.Code, w.Body.String())
			}
			if _, err := st.GetGlobalRecipient(u.AccountID); !errors.Is(err, store.ErrNotFound) {
				t.Fatal("disabled global route created a recipient")
			}
			updated, _ := st.GetUserByAccountID(u.AccountID)
			if updated.StripeAccountCountry != country {
				t.Fatalf("Connect country lost: %+v", updated)
			}
		})
	}
}

type failingGlobalPayoutPersistence struct {
	*memory.MemoryStore
	recordFailures, refundFailures, recordCalls, refundCalls int
	claimOffset                                              time.Duration
}

func TestGlobalPayoutDefinitiveRejectionSurvivesRefundFailure(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.HandleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.HandleGlobalPayoutQuote)
	var q struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &q)
	wrapper := &failingGlobalPayoutPersistence{MemoryStore: st, recordFailures: 1, refundFailures: 1}
	cfg := billing.Config{MockMode: true, StripeGlobalPayoutsEnabled: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp"}
	baseURL := s.billing.GlobalPayouts().BaseURL
	s.SetService(billing.NewService(wrapper, s.billing.Ledger(), s.logger, cfg))
	s.billing.GlobalPayouts().BaseURL = baseURL
	f.mu.Lock()
	f.rejectRequests = true
	f.mu.Unlock()
	w = globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+q.ID+`"}`, s.HandleStripeWithdraw)
	if w.Code != 202 {
		t.Fatal(w.Body.String())
	}
	p, _ := st.GetGlobalPayout(q.ID)
	if p.Rejection == nil || p.Refunded || wrapper.recordCalls != 2 {
		t.Fatalf("rejection not durable before failed refund: %+v", p)
	}
	// Permissions recover before the next worker. A second Send would now move money.
	f.mu.Lock()
	f.rejectRequests = false
	f.mu.Unlock()
	wrapper.claimOffset = 2 * time.Minute
	s.SetService(billing.NewService(wrapper, s.billing.Ledger(), s.logger, cfg))
	s.billing.GlobalPayouts().BaseURL = baseURL
	if err := s.syncGlobalPayout(context.Background(), q.ID); err != nil {
		t.Fatal(err)
	}
	if err := s.syncGlobalPayout(context.Background(), q.ID); err != nil {
		t.Fatal(err)
	}
	p, _ = st.GetGlobalPayout(q.ID)
	if !p.Refunded || p.DispatchAttempts != 1 || f.creates != 0 || st.GetWithdrawableBalance(u.AccountID) != 20_000_000 {
		t.Fatalf("failed refund led to redispatch or stranded earnings: %+v, creates=%d", p, f.creates)
	}
}
