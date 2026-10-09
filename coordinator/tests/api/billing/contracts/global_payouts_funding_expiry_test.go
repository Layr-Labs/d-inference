package billing_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/internal/billing/payoutrecovery"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestGlobalFundingQueueRefreshAcceptsFXQuoteWithoutLockExpiry(t *testing.T) {
	srv, st, user, stripe := globalPayoutAPIFixture(t, false)
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v2/money_management/outbound_payment_quotes" {
			stripe.serve(w, r)
			return
		}
		response := httptest.NewRecorder()
		stripe.serve(response, r)
		var quote map[string]json.RawMessage
		if err := json.Unmarshal(response.Body.Bytes(), &quote); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		quote["fx_quote"] = json.RawMessage(`{}`)
		_ = json.NewEncoder(w).Encode(quote)
	}))
	defer remote.Close()
	srv.Billing().GlobalPayouts().BaseURL = remote.URL
	if w := globalAPIRequest(t, srv, user, "/v1/billing/stripe/onboard", `{"country":"IN"}`); w.Code != http.StatusOK {
		t.Fatal(w.Body.String())
	}
	w := globalAPIRequest(t, srv, user, "/v1/billing/stripe/quote", `{"amount_usd":"10"}`)
	var quote struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &quote); err != nil || w.Code != http.StatusOK || quote.ID == "" {
		t.Fatalf("initial quote rejected optional expiry: %d %s", w.Code, w.Body.String())
	}
	p, err := st.GetGlobalPayout(quote.ID)
	if err != nil {
		t.Fatal(err)
	}
	// Recreate the approved quote on an earlier clock to exercise expiration
	// after a funding wait without waiting for wall-clock minutes.
	now := time.Now()
	p.ID = "expired-funding-quote"
	p.CreatedAt, p.ExpiresAt = now.Add(-3*time.Minute), now.Add(-time.Minute)
	var request globalpayouts.PaymentRequest
	if err := json.Unmarshal(p.Request, &request); err != nil {
		t.Fatal(err)
	}
	request.Metadata["darkbloom_withdrawal_id"] = p.ID
	if p.Request, err = json.Marshal(request); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateGlobalPayoutQuote(*p); err != nil {
		t.Fatal(err)
	}
	if _, err := st.BeginGlobalPayout(user.AccountID, p.ID, now.Add(-2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	claimed, err := st.ClaimGlobalPayout(p.ID, now.Add(-2*time.Minute))
	if err != nil || claimed == nil {
		t.Fatalf("queue claim: %+v, %v", claimed, err)
	}
	if err := st.ApplyGlobalPayout(p.ID, store.GlobalPayoutResult{ExpectedLease: claimed.LeaseUntil, Status: "queued", FailureCode: store.WithdrawalFundingReason}, now.Add(-2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := payoutrecovery.New(srv.Billing(), srv.logger).SyncGlobalPayout(context.Background(), p.ID); err != nil {
		t.Fatal(err)
	}
	got, err := st.GetGlobalPayout(p.ID)
	if err != nil || got.Status != "processing" || got.ExternalID != "obp_gp" || got.Refunded || got.DispatchAttempts != 1 || !got.ExpiresAt.After(now) {
		t.Fatalf("refreshed optional expiry stranded funding queue: %+v, %v", got, err)
	}
	if b, wb := st.GetBalanceWithWithdrawable(user.AccountID); b != 10_000_000 || wb != b {
		t.Fatalf("quote refresh repeated debit or refunded payout: %d, %d", b, wb)
	}
	stripe.mu.Lock()
	defer stripe.mu.Unlock()
	if stripe.quoteCalls != 2 || stripe.creates != 1 {
		t.Fatalf("refresh/sends=%d/%d, want 2/1", stripe.quoteCalls, stripe.creates)
	}
}
