package billing_test

import (
	"testing"
)

func TestGlobalPayoutBankLookupFailurePreservesReadyDestination(t *testing.T) {
	s, st, u, f := globalPayoutAPIFixture(t, false)
	globalAPIRequest(t, s, u, "/v1/billing/stripe/onboard", `{"country":"IN"}`)
	w := globalAPIRequest(t, s, u, "/v1/billing/stripe/quote", `{"amount_usd":"10"}`)
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	original, _ := st.GetGlobalRecipient(u.AccountID)
	for _, code := range []int{429, 500} {
		f.mu.Lock()
		f.bankStatus = code
		f.mu.Unlock()
		for _, path := range []string{"/v1/billing/stripe/status?refresh=1", "/v1/billing/stripe/quote?refresh=1"} {
			w = globalAPIRequest(t, s, u, path, `{"amount_usd":"10"}`)
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
	w = globalAPIRequest(t, s, u, "/v1/billing/stripe/quote", `{"amount_usd":"10"}`)
	after, _ := st.GetGlobalRecipient(u.AccountID)
	if w.Code != 409 || after.Ready {
		t.Fatalf("successful empty lookup should require bank setup: %d %+v", w.Code, after)
	}
}
