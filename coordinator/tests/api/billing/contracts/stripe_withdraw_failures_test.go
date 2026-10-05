package billing_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestStripeWithdrawTransferFailureRefunds exercises the ledger-refund branch
// when Stripe rejects transfers.create. We use a real-HTTP Stripe Connect
// client backed by a fake Stripe server that returns 400 on /v1/transfers.
func TestStripeWithdrawTransferFailureRefunds(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-w-fail", "US", "full", false)))
			return
		}
		if r.URL.Path == "/v1/transfers" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":{"message":"insufficient platform funds","type":"invalid_request_error"}}`))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-fail", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance after refund = %d, want 10_000_000 (full original)", bal)
	}
	// Ledger should now have: deposit (+10), charge (-5), refund (+5).
	entries := st.LedgerHistory(user.AccountID)
	if len(entries) != 3 {
		t.Fatalf("expected 3 ledger entries, got %d", len(entries))
	}
	// Newest first: refund, charge, deposit.
	if entries[0].Type != store.LedgerRefund {
		t.Errorf("entries[0].Type = %q, want refund", entries[0].Type)
	}
}

func TestStripeWithdrawTransferFailureMarksRowFailedAndRefunded(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-w-marked", "US", "full", false)))
			return
		}
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"boom","type":"invalid_request_error"}}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-marked", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502", w.Code)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Status != "failed" {
		t.Errorf("status = %q, want failed", wds[0].Status)
	}
	if !wds[0].Refunded {
		t.Error("refunded flag should be set")
	}
	if !strings.Contains(wds[0].FailureReason, "transfer_create_failed") {
		t.Errorf("failure_reason = %q", wds[0].FailureReason)
	}
}

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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

// TestStripeWithdrawAccountGonePreCheckUnlinksWithoutDebit pins that a
// withdrawal against a closed Stripe account fails BEFORE the ledger debit
// and unlinks the dead account.
func TestStripeWithdrawAccountGonePreCheckUnlinksWithoutDebit(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"message":"No such account: 'acct_acct-w-gone'","type":"invalid_request_error"}}`))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-gone", "gone@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "stripe_account_gone" {
		t.Errorf("error type = %v", errObj["type"])
	}
	// No debit happened.
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance = %d, want 10_000_000 (untouched)", bal)
	}
	// Dead account unlinked so the user can re-onboard.
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want empty after unlink", refreshed.StripeAccountID)
	}
	// No withdrawal row persisted.
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 0 {
		t.Errorf("expected no withdrawal rows, got %d", len(wds))
	}
}

// TestStripeWithdrawServiceAgreementMismatchPreCheck pins the AU/NZ/JP
// experience: withdrawing against a full-agreement account outside the
// transfer region returns an actionable "recreate" error before any debit
// and flips the local status to restricted.
func TestStripeWithdrawServiceAgreementMismatchPreCheck(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-w-au", "AU", "full", false)))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-au", "au@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "stripe_account_recreate_required" {
		t.Errorf("error type = %v", errObj["type"])
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance = %d, want 10_000_000 (untouched)", bal)
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountStatus != "restricted" {
		t.Errorf("status = %q, want restricted (prompts re-onboarding)", refreshed.StripeAccountStatus)
	}
}

// TestStripeWithdrawAgreementMismatchWithOmittedField pins the REAL Stripe
// API shape, verified against the live platform: accounts under the full
// agreement OMIT tos_acceptance.service_agreement entirely (only date/ip are
// present). The mismatch detection must normalize the absent field to "full"
// — treating it as unknown silently skipped every broken AU/NZ/JP account.
func TestStripeWithdrawAgreementMismatchWithOmittedField(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			// Verbatim shape of a live AU full-agreement Express account.
			_, _ = w.Write([]byte(`{
				"id": "acct_acct-w-au-real",
				"country": "AU",
				"default_currency": "aud",
				"payouts_enabled": true,
				"details_submitted": true,
				"tos_acceptance": {"date": 1782738707},
				"capabilities": {"card_payments": "active", "transfers": "active"},
				"settings": {"payouts": {"schedule": {"delay_days": 2, "interval": "manual"}}},
				"external_accounts": {"data": [{"object":"bank_account","last4":"6789","default_for_currency":true}]}
			}`))
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodPost {
			// Schedule self-heal fires for the manual interval — accept it.
			_, _ = w.Write([]byte(`{"id":"acct_acct-w-au-real"}`))
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-w-au-real", "au-real@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409 (absent service_agreement must normalize to full): %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "stripe_account_recreate_required" {
		t.Errorf("error type = %v", errObj["type"])
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance = %d, want untouched", bal)
	}
}
