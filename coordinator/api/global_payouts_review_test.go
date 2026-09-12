package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestGlobalPayoutDisabledPreservesLegacyConnect(t *testing.T) {
	for _, country := range []string{"AU", "IN", "JP", "BR", "GH", "NG"} {
		t.Run(country, func(t *testing.T) {
			s, st, u, _ := globalPayoutAPIFixture(t, false)
			s.SetBilling(billing.NewService(st, s.billing.Ledger(), s.logger, billing.Config{MockMode: true, StripeConnectReturnURL: "https://app.test/billing", StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp"}))
			if s.billing.GlobalPayouts() == nil {
				t.Fatal("test must configure the disabled client")
			}
			if s.payoutCountries() != nil {
				t.Fatal("disabled flag replaced the legacy country menu")
			}
			w := globalAPIRequest(t, s, u, "/onboard", `{"country":"`+country+`"}`, s.handleStripeOnboard)
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

func TestGlobalPayoutBankLookupFailurePreservesReadyDestination(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.handleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	original, _ := st.GetGlobalRecipient(u.AccountID)
	for _, code := range []int{429, 500} {
		f.mu.Lock()
		f.bankStatus = code
		f.mu.Unlock()
		for _, handler := range []http.HandlerFunc{s.handleStripeStatus, s.handleGlobalPayoutQuote} {
			w = globalAPIRequest(t, s, u, "/?refresh=1", `{"amount_usd":"10"}`, handler)
			if w.Code != 502 {
				t.Fatalf("transient Stripe failure became onboarding failure: %d %s", w.Code, w.Body.String())
			}
			after, _ := st.GetGlobalRecipient(u.AccountID)
			if *after != *original {
				t.Fatalf("transient failure changed destination: %+v", after)
			}
		}
	}
	f.mu.Lock()
	f.bankStatus = 0
	f.emptyBanks = true
	f.mu.Unlock()
	w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	after, _ := st.GetGlobalRecipient(u.AccountID)
	if w.Code != 409 || after.Ready {
		t.Fatalf("successful empty lookup should require bank setup: %d %+v", w.Code, after)
	}
}

type failingGlobalPayoutPersistence struct {
	*store.MemoryStore
	recordFailures, refundFailures, recordCalls, refundCalls int
	claimOffset                                              time.Duration
}

func (f *failingGlobalPayoutPersistence) RecordGlobalPayoutRejection(id string, attempt int, code string) error {
	f.recordCalls++
	if f.recordFailures > 0 {
		f.recordFailures--
		return errors.New("temporary rejection write failure")
	}
	return f.MemoryStore.RecordGlobalPayoutRejection(id, attempt, code)
}
func (f *failingGlobalPayoutPersistence) ApplyGlobalPayout(id string, result store.GlobalPayoutResult, now time.Time) error {
	f.refundCalls++
	if f.refundFailures > 0 {
		f.refundFailures--
		return errors.New("temporary refund transaction failure")
	}
	return f.MemoryStore.ApplyGlobalPayout(id, result, now)
}
func (f *failingGlobalPayoutPersistence) ClaimGlobalPayout(id string, now time.Time) (bool, error) {
	return f.MemoryStore.ClaimGlobalPayout(id, now.Add(f.claimOffset))
}

func TestGlobalPayoutDefinitiveRejectionSurvivesRefundFailure(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.handleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.handleGlobalPayoutQuote)
	var q struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &q)
	wrapper := &failingGlobalPayoutPersistence{MemoryStore: st, recordFailures: 1, refundFailures: 1}
	cfg := billing.Config{MockMode: true, StripeGlobalPayoutsEnabled: true, StripeGlobalPayoutsFinancialAccount: "fa_gp", StripeGlobalPayoutsSecretKey: "rk_test_gp"}
	baseURL := s.billing.GlobalPayouts().BaseURL
	s.SetBilling(billing.NewService(wrapper, s.billing.Ledger(), s.logger, cfg))
	s.billing.GlobalPayouts().BaseURL = baseURL
	f.mu.Lock()
	f.rejectRequests = true
	f.mu.Unlock()
	w = globalAPIRequest(t, s, u, "/withdraw", `{"amount_usd":"10","quote_id":"`+q.ID+`"}`, s.handleStripeWithdraw)
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
	s.SetBilling(billing.NewService(wrapper, s.billing.Ledger(), s.logger, cfg))
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
