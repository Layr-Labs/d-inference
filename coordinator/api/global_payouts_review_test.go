package api

import (
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestGlobalPayoutBankLookupFailurePreservesReadyDestination(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/onboard", `{"country":"IN"}`, s.payouts.HandleStripeOnboard)
	w := globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.payouts.HandleGlobalPayoutQuote)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	original, _ := st.GetGlobalRecipient(u.AccountID)
	for _, code := range []int{429, 500} {
		f.mu.Lock()
		f.bankStatus = code
		f.mu.Unlock()
		for _, handler := range []http.HandlerFunc{s.payouts.HandleStripeStatus, s.payouts.HandleGlobalPayoutQuote} {
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
	w = globalAPIRequest(t, s, u, "/quote", `{"amount_usd":"10"}`, s.payouts.HandleGlobalPayoutQuote)
	after, _ := st.GetGlobalRecipient(u.AccountID)
	if w.Code != 409 || after.Ready {
		t.Fatalf("successful empty lookup should require bank setup: %d %+v", w.Code, after)
	}
}

type failingGlobalPayoutPersistence struct {
	*memory.MemoryStore
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
