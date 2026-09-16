package billing

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStripeWithdrawTransferOkInstantPayoutFailRefundsFeeOnly(t *testing.T) {
	// Instant withdrawal: transfer succeeds, payouts.create fails. The funds
	// stay in the connected account (Stripe's daily auto-payout delivers via
	// the standard rail), so the principal is NOT refunded — but the instant
	// fee IS, because the user isn't getting instant delivery. Row stays at
	// "transferred" with FailureReason set.
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-tr-only", "US", "full", true)))
			return
		}
		switch r.URL.Path {
		case "/v1/transfers":
			_, _ = w.Write([]byte(`{"id":"tr_ok","amount":450,"destination":"acct_x","created":1700000000}`))
		case "/v1/payouts":
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"insufficient connected balance"}}`))
		default:
			t.Errorf("unexpected: %s", r.URL.Path)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-tr-only", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	// $5 instant → fee floor $0.50 → net $4.50 transferred.
	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeWithdraw(w, req)

	if w.Code != http.StatusAccepted {
		t.Fatalf("got %d, want 202: %s", w.Code, w.Body.String())
	}
	// Seed $10 − gross $5 + fee refund $0.50 = $5.50. The $4.50 principal is
	// in the connected account, en route via the daily sweep.
	if bal := st.GetBalance(user.AccountID); bal != 5_500_000 {
		t.Errorf("balance = %d, want 5_500_000 (fee refunded, principal in connected acct)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if wds[0].Status != "transferred" {
		t.Errorf("status = %q, want transferred", wds[0].Status)
	}
	if wds[0].Refunded {
		t.Error("refunded flag should NOT be set (principal not refunded)")
	}
	if wds[0].TransferID != "tr_ok" {
		t.Errorf("transfer_id = %q", wds[0].TransferID)
	}
	if !strings.Contains(wds[0].FailureReason, "instant_payout_create_failed") {
		t.Errorf("failure_reason = %q", wds[0].FailureReason)
	}
	if !strings.Contains(wds[0].FailureReason, "fee refunded") {
		t.Errorf("failure_reason should note the fee refund, got %q", wds[0].FailureReason)
	}
}

// TestStripeWithdrawNoInflationOnFailedPayout verifies that a failed payout
// followed by a refund does not inflate the withdrawable balance beyond its
// original value. This was the core accounting bug: Debit ate non-withdrawable
// credits, but CreditWithdrawable restored the amount as withdrawable earnings.
func TestStripeWithdrawNoInflationOnFailedPayout(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/transfers" && r.Method == http.MethodPost:
			w.WriteHeader(400)
			_, _ = w.Write([]byte(`{"error":{"message":"boom","type":"invalid_request_error"}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-inflate-1", "inflate@example.com", false)

	// Seed: $100 total, $50 withdrawable (earned), $50 non-withdrawable (credits).
	st.Credit(user.AccountID, 50_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 50_000_000, store.LedgerPayout, "earnings")

	beforeBalance := st.GetBalance(user.AccountID)
	beforeWithdrawable := st.GetWithdrawableBalance(user.AccountID)
	if beforeBalance != 100_000_000 {
		t.Fatalf("initial balance = %d, want 100_000_000", beforeBalance)
	}
	if beforeWithdrawable != 50_000_000 {
		t.Fatalf("initial withdrawable = %d, want 50_000_000", beforeWithdrawable)
	}

	// Attempt a $10 withdrawal — transfer will fail, triggering refund.
	body := `{"amount_usd":"10.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeWithdraw(w, req)

	// Transfer fails → refund should restore original balances exactly.
	afterBalance := st.GetBalance(user.AccountID)
	afterWithdrawable := st.GetWithdrawableBalance(user.AccountID)

	if afterBalance != beforeBalance {
		t.Errorf("balance after failed withdrawal = %d, want %d (unchanged)", afterBalance, beforeBalance)
	}
	if afterWithdrawable != beforeWithdrawable {
		t.Errorf("withdrawable after failed withdrawal = %d, want %d (unchanged) — inflation bug!", afterWithdrawable, beforeWithdrawable)
	}
}
