package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// --- Withdraw ---

func TestStripeWithdrawRejectsWithoutOnboarding(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-w-1", "alice@example.com")
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("got %d, want 403", w.Code)
	}
}


func TestStripeWithdrawRejectsBelowMinimum(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-min", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"0.50","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400", w.Code)
	}
}


func TestStripeWithdrawRejectsInstantWithoutDebitCard(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-inst-1", "alice@example.com", false /* instant_eligible */)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "instant_unavailable" {
		t.Errorf("error type = %v", errObj["type"])
	}
}


func TestStripeWithdrawStandardSuccess(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-std", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["fee_usd"] != "0.00" {
		t.Errorf("standard fee should be 0, got %v", resp["fee_usd"])
	}
	if resp["net_usd"] != "5.00" {
		t.Errorf("net should equal gross for standard, got %v", resp["net_usd"])
	}
	if resp["amount_usd"] != "5.00" {
		t.Errorf("amount = %v", resp["amount_usd"])
	}
	if balance, _ := resp["balance_micro_usd"].(float64); int64(balance) != 5_000_000 {
		t.Errorf("balance = %v, want 5_000_000", resp["balance_micro_usd"])
	}

	// Confirm a withdrawal row was persisted.
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Method != "standard" {
		t.Errorf("method = %q", wds[0].Method)
	}
	if wds[0].FeeMicroUSD != 0 {
		t.Errorf("persisted fee = %d", wds[0].FeeMicroUSD)
	}
	if wds[0].NetMicroUSD != 5_000_000 {
		t.Errorf("persisted net = %d", wds[0].NetMicroUSD)
	}
}


func TestStripeWithdrawInstantAppliesFee(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-inst", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 100_000_000, store.LedgerDeposit, "seed")

	// $50 instant → 1.5% fee = $0.75 → net $49.25 → balance after = $50
	body := `{"amount_usd":"50.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["fee_usd"] != "0.75" {
		t.Errorf("fee_usd = %v, want 0.75", resp["fee_usd"])
	}
	if resp["net_usd"] != "49.25" {
		t.Errorf("net_usd = %v, want 49.25", resp["net_usd"])
	}
	if resp["amount_usd"] != "50.00" {
		t.Errorf("amount_usd = %v", resp["amount_usd"])
	}
	if resp["eta"] != "~30 minutes" {
		t.Errorf("eta = %v", resp["eta"])
	}
	if balance, _ := resp["balance_micro_usd"].(float64); int64(balance) != 50_000_000 {
		t.Errorf("balance = %v, want 50_000_000", resp["balance_micro_usd"])
	}
}


func TestStripeWithdrawSmallInstantHitsFloor(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-small", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	// $5 instant → 1.5% = $0.075 < $0.50 → fee snaps to $0.50 → net $4.50
	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["fee_usd"] != "0.50" {
		t.Errorf("fee_usd = %v, want 0.50 (floor)", resp["fee_usd"])
	}
	if resp["net_usd"] != "4.50" {
		t.Errorf("net_usd = %v", resp["net_usd"])
	}
}


func TestStripeWithdrawInsufficientBalance(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-poor", "alice@example.com", false)
	// No credit seeded.

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400", w.Code)
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	errObj, _ := resp["error"].(map[string]any)
	if errObj["type"] != "insufficient_withdrawable" {
		t.Errorf("error type = %v", errObj["type"])
	}
}




func TestStripeWithdrawPersistsRowAsPendingFirst(t *testing.T) {
	// Verify the row exists before any Stripe call returns. We use a fake
	// Stripe that records when CreateTransfer is called and the test then
	// asserts that the DB had a "pending" row at that moment.
	var rowSeenAtTransferTime *store.StripeWithdrawal
	st := store.NewMemory(store.Config{AdminKey: "test-key"})

	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			_, _ = w.Write([]byte(healthyAccountJSON("acct_acct-pers-1", "US", "full", false)))
			return
		}
		if r.URL.Path == "/v1/transfers" {
			// Snapshot the only withdrawal in the store at the moment of the
			// transfer call; should already be persisted with status=pending.
			wds, _ := st.ListStripeWithdrawals("acct-pers-1", 0)
			if len(wds) == 1 {
				cp := wds[0]
				rowSeenAtTransferTime = &cp
			}
			_, _ = w.Write([]byte(`{"id":"tr_pers","amount":500,"destination":"acct_x","created":1700000000}`))
			return
		}
		// Standard withdrawals must NOT create manual payouts — Stripe's
		// automatic daily schedule delivers the funds.
		t.Errorf("unexpected Stripe call: %s", r.URL.Path)
	}))
	defer fakeStripe.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	t.Cleanup(setStripeAPIBase(fakeStripe.URL))
	ledger := payments.NewLedger(st)
	srv.SetBilling(billing.NewService(st, ledger, logger, billing.Config{
		StripeSecretKey:              "sk_test_fake",
		StripeConnectWebhookSecret:   "whsec_test",
		StripeConnectReturnURL:       "https://app.test/billing",
		StripeConnectRefreshURL:      "https://app.test/billing",
		StripeConnectPlatformCountry: "US",
	}))

	user := readyUser(t, st, "acct-pers-1", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	if rowSeenAtTransferTime == nil {
		t.Fatal("withdrawal row should have been persisted before the transfer call")
	}
	if rowSeenAtTransferTime.Status != "pending" {
		t.Errorf("at transfer-time status was %q, want pending", rowSeenAtTransferTime.Status)
	}

	// Final state: transferred, no payout ID — delivery is Stripe's
	// automatic daily sweep, whose payout.paid webhook completes the row.
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Status != "transferred" {
		t.Errorf("final status = %q, want transferred", wds[0].Status)
	}
	if wds[0].TransferID != "tr_pers" {
		t.Errorf("transfer id not persisted: %+v", wds[0])
	}
	if wds[0].PayoutID != "" {
		t.Errorf("standard withdrawal should have no payout id, got %q", wds[0].PayoutID)
	}
}


func TestStripeWithdrawDefinitiveTransferFailureRefundsAndMarksFailed(t *testing.T) {
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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance after refund = %d, want 10_000_000", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("expected 1 withdrawal row, got %d", len(wds))
	}
	if wds[0].Status != "failed" || !wds[0].Refunded {
		t.Errorf("row = status %q refunded=%v, want failed/true", wds[0].Status, wds[0].Refunded)
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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

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
	srv.handleStripeWithdraw(w, req)

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

// silence unused-import linter when tests are pruned during iteration.
var (
	_ = io.Discard
	_ = url.QueryEscape
	_ = sync.Mutex{}
)


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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

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


// --- Express Dashboard link ---
//
// The self-serve path for changing the payout bank account on an already
// onboarded account. The onboarding link can't do this (it only collects
// outstanding requirements, and a ready account has none), so this endpoint is
// the only thing standing between a provider and a support ticket.

func TestStripeDashboardLinkRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
	}
}


func TestStripeDashboardLinkRequiresLinkedAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-dash-none", "nobank@example.com")

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	if got := errorTypeOf(t, w.Body.Bytes()); got != "not_onboarded" {
		t.Errorf("error type = %q", got)
	}
}


// Stripe has no Express Dashboard to log into until the account submits its
// details, so a half-onboarded account must be told to finish setup rather
// than handed a raw Stripe error suggesting a retry that can never work.
// Restricted and rejected accounts DO have a dashboard and must get through.
func TestStripeDashboardLinkStatusGate(t *testing.T) {
	cases := []struct {
		status   string
		wantCode int
	}{
		{"", http.StatusConflict},
		{stripeStatusPending, http.StatusConflict},
		{stripeStatusReady, http.StatusOK},
		{stripeStatusRestricted, http.StatusOK},
		{stripeStatusRejected, http.StatusOK},
	}
	for _, tc := range cases {
		name := tc.status
		if name == "" {
			name = "empty"
		}
		t.Run(name, func(t *testing.T) {
			srv, st := stripePayoutsTestServer(t, true, nil)
			user := seedUser(t, st, "acct-dash-"+name, name+"@example.com")
			if err := st.SetUserStripeAccount(user.AccountID, "acct_dash_"+name, tc.status, "US", "bank", "6789", false); err != nil {
				t.Fatal(err)
			}
			user, _ = st.GetUserByAccountID(user.AccountID)

			req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
			req = withPrivyUser(req, user)
			w := httptest.NewRecorder()
			srv.handleStripeDashboardLink(w, req)

			if w.Code != tc.wantCode {
				t.Fatalf("status %q: got %d, want %d: %s", tc.status, w.Code, tc.wantCode, w.Body.String())
			}
			if tc.wantCode == http.StatusConflict {
				if got := errorTypeOf(t, w.Body.Bytes()); got != "not_onboarded" {
					t.Errorf("error type = %q, want not_onboarded", got)
				}
			}
		})
	}
}


// The route-level middleware is the only thing keeping API keys out: requireAuth
// also populates the user context for account-bound keys and provider device
// tokens, so requirePrivyUser inside the handler is not a second line of
// defense. Drive the real mux so a swap to requireAuth can't pass CI.
func TestStripeDashboardLinkRouteRejectsAPIKey(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-dash-key", "keyholder@example.com", false)

	rawKey, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
	if err != nil {
		t.Fatalf("create api key: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req.Header.Set("Authorization", "Bearer "+rawKey)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("got %d, want 403 (API keys must not mint payout dashboard sessions): %s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), "connect.stripe.com") {
		t.Error("response leaked a login link to an API-key caller")
	}
}


func TestStripeDashboardLinkReturnsLoginURL(t *testing.T) {
	var mu sync.Mutex
	var gotPath string
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		gotPath = r.URL.Path
		mu.Unlock()
		_, _ = w.Write([]byte(`{"object":"login_link","url":"https://connect.stripe.com/express/acct_x/tok"}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-dash-ok", "dash@example.com", false)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["url"] != "https://connect.stripe.com/express/acct_x/tok" {
		t.Errorf("url = %v", resp["url"])
	}
	if resp["stripe_account_id"] != user.StripeAccountID {
		t.Errorf("stripe_account_id = %v, want %q", resp["stripe_account_id"], user.StripeAccountID)
	}
	mu.Lock()
	defer mu.Unlock()
	if want := "/v1/accounts/" + user.StripeAccountID + "/login_links"; gotPath != want {
		t.Errorf("Stripe path = %q, want %q", gotPath, want)
	}
}


// An account the user closed on Stripe's side must be unlinked here too,
// otherwise the UI keeps offering a button that can only ever fail.
func TestStripeDashboardLinkUnlinksGoneAccount(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"code":"account_invalid","message":"No such account"}}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-dash-gone", "gone@example.com", false)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusConflict {
		t.Fatalf("got %d, want 409: %s", w.Code, w.Body.String())
	}
	if got := errorTypeOf(t, w.Body.Bytes()); got != "stripe_account_gone" {
		t.Errorf("error type = %q", got)
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want cleared", refreshed.StripeAccountID)
	}
}


// A transient Stripe failure must not unlink the account — the user's payout
// destination is still perfectly valid.
func TestStripeDashboardLinkKeepsAccountOnTransientError(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":{"type":"api_error","message":"Stripe is down"}}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-dash-5xx", "flaky@example.com", false)

	req := httptest.NewRequest(http.MethodPost, "/v1/billing/stripe/dashboard", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeDashboardLink(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != user.StripeAccountID {
		t.Errorf("StripeAccountID = %q, want %q (untouched)", refreshed.StripeAccountID, user.StripeAccountID)
	}
	if refreshed.StripeAccountStatus != "ready" {
		t.Errorf("status = %q, want ready (untouched)", refreshed.StripeAccountStatus)
	}
}


// errorTypeOf pulls error.type out of a coordinator error envelope.
func errorTypeOf(t *testing.T, body []byte) string {
	t.Helper()
	var resp map[string]any
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("unmarshal error body %q: %v", body, err)
	}
	errObj, _ := resp["error"].(map[string]any)
	s, _ := errObj["type"].(string)
	return s
}


// --- Unlink ---

func TestStripeUnlinkClearsAccount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-unlink-1", "unlink@example.com", false)

	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeUnlink(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["unlinked"] != true {
		t.Errorf("unlinked = %v, want true", resp["unlinked"])
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID != "" {
		t.Errorf("StripeAccountID = %q, want empty", refreshed.StripeAccountID)
	}
	if refreshed.StripeAccountStatus != "" {
		t.Errorf("status = %q, want empty", refreshed.StripeAccountStatus)
	}

	// Second unlink is a no-op.
	refreshed, _ = st.GetUserByAccountID(user.AccountID)
	req2 := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req2 = withPrivyUser(req2, refreshed)
	w2 := httptest.NewRecorder()
	srv.handleStripeUnlink(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("second unlink got %d", w2.Code)
	}
	var resp2 map[string]any
	_ = json.Unmarshal(w2.Body.Bytes(), &resp2)
	if resp2["unlinked"] != false {
		t.Errorf("second unlink = %v, want false", resp2["unlinked"])
	}
}


func TestStripeUnlinkRequiresAuth(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	w := httptest.NewRecorder()
	srv.handleStripeUnlink(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Errorf("got %d, want 401", w.Code)
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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

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


// TestStripeWithdrawAbortsWhenScheduleHealFails: a legacy manual-schedule
// account whose heal-to-daily update fails must abort BEFORE the ledger
// debit — standard delivery depends entirely on the daily sweep.
func TestStripeWithdrawAbortsWhenScheduleHealFails(t *testing.T) {
	manualAccountJSON := strings.Replace(
		healthyAccountJSON("acct_acct-heal-fail", "US", "full", false),
		`"interval":"daily"`, `"interval":"manual"`, 1)
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") {
			if r.Method == http.MethodGet {
				_, _ = w.Write([]byte(manualAccountJSON))
				return
			}
			// The heal (POST /v1/accounts/{id}) fails.
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":{"message":"api unavailable"}}`))
			return
		}
		t.Errorf("unexpected Stripe call after failed heal: %s %s", r.Method, r.URL.Path)
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-heal-fail", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance = %d, want 10_000_000 (no debit before abort)", bal)
	}
	if wds, _ := st.ListStripeWithdrawals(user.AccountID, 0); len(wds) != 0 {
		t.Errorf("no withdrawal row should exist, got %d", len(wds))
	}
}


// TestStripeUnlinkRouteRejectsAPIKey: unlink is account management — it must
// require an interactive Privy session, not be reachable with a (leakable)
// inference API key.
func TestStripeUnlinkRouteRejectsAPIKey(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-unlink-key", "alice@example.com", false)

	rawKey, _, err := st.CreateAPIKey(user.AccountID, store.APIKeyCreate{})
	if err != nil {
		t.Fatalf("create api key: %v", err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/v1/billing/stripe/account", nil)
	req.Header.Set("Authorization", "Bearer "+rawKey)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("got %d, want 403 (API keys must not unlink payout accounts): %s", w.Code, w.Body.String())
	}
	refreshed, _ := st.GetUserByAccountID(user.AccountID)
	if refreshed.StripeAccountID == "" {
		t.Error("account must still be linked")
	}
}


// --- Round-5: ambiguous Stripe outcomes must never auto-refund ---

// droppingStripe builds a fake Stripe that serves a healthy account on GET
// /v1/accounts/*, drops the connection (transport error, outcome unknown) for
// the first failN requests to dropPath, and delegates the rest to next.
func droppingStripe(t *testing.T, dropPath string, failN int, next http.HandlerFunc) *httptest.Server {
	t.Helper()
	var calls int32
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
			id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
			_, _ = w.Write([]byte(healthyAccountJSON(id, "US", "full", true)))
			return
		}
		if r.URL.Path == dropPath && atomic.AddInt32(&calls, 1) <= int32(failN) {
			hj, ok := w.(http.Hijacker)
			if !ok {
				t.Fatal("recorder not hijackable")
			}
			conn, _, err := hj.Hijack()
			if err != nil {
				t.Fatalf("hijack: %v", err)
			}
			_ = conn.Close() // response lost in flight — ambiguous outcome
			return
		}
		if next != nil {
			next(w, r)
			return
		}
		t.Errorf("unexpected Stripe call: %s %s", r.Method, r.URL.Path)
	}))
}


// Stripe transport failures are indeterminate: the mutation may have landed,
// so every ambiguous failure parks the debited row for reconciliation.
func TestStripeWithdrawAmbiguousTransferParksRowWithoutRefund(t *testing.T) {
	tests := []struct {
		name             string
		newStripe        func(*testing.T) (*httptest.Server, func() int32)
		expectedAttempts int32
	}{
		{
			name: "dropped response",
			newStripe: func(t *testing.T) (*httptest.Server, func() int32) {
				return droppingStripe(t, "/v1/transfers", 99, nil), nil
			},
		},
		{
			name: "server error",
			newStripe: func(t *testing.T) (*httptest.Server, func() int32) {
				var transferCalls int32
				fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if strings.HasPrefix(r.URL.Path, "/v1/accounts/") && r.Method == http.MethodGet {
						id := strings.TrimPrefix(r.URL.Path, "/v1/accounts/")
						_, _ = w.Write([]byte(healthyAccountJSON(id, "US", "full", false)))
						return
					}
					if r.URL.Path == "/v1/transfers" {
						atomic.AddInt32(&transferCalls, 1)
						w.WriteHeader(http.StatusInternalServerError)
						_, _ = w.Write([]byte(`{"error":{"message":"An unknown error occurred","type":"api_error"}}`))
					}
				}))
				return fakeStripe, func() int32 { return atomic.LoadInt32(&transferCalls) }
			},
			expectedAttempts: 3,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			fakeStripe, attempts := tt.newStripe(t)
			defer fakeStripe.Close()

			srv, st := stripePayoutsTestServer(t, false, fakeStripe)
			accountID := "acct-ambiguous-" + strings.ReplaceAll(tt.name, " ", "-")
			user := readyUser(t, st, accountID, "alice@example.com", false)
			st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

			body := `{"amount_usd":"5.00","method":"standard"}`
			req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
			req = withPrivyUser(req, user)
			w := httptest.NewRecorder()
			srv.handleStripeWithdraw(w, req)

			if w.Code != http.StatusBadGateway {
				t.Fatalf("got %d, want 502: %s", w.Code, w.Body.String())
			}
			if attempts != nil && attempts() != tt.expectedAttempts {
				t.Errorf("transfer attempts = %d, want %d", attempts(), tt.expectedAttempts)
			}
			if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
				t.Errorf("balance = %d, want 5_000_000 (ambiguous mutation is not refunded)", bal)
			}
			wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
			if len(wds) != 1 {
				t.Fatalf("want 1 withdrawal row, got %d", len(wds))
			}
			if wds[0].Status != "pending" || wds[0].Refunded {
				t.Errorf("row = status %q refunded=%v, want pending/false", wds[0].Status, wds[0].Refunded)
			}
			if !strings.Contains(wds[0].FailureReason, "transfer_create_unconfirmed") {
				t.Errorf("failure reason = %q, want transfer_create_unconfirmed", wds[0].FailureReason)
			}
		})
	}
}


// TestStripeWithdrawAmbiguousTransferRetryRecovers: a single dropped response
// followed by a successful idempotent replay completes the withdrawal
// normally — one debit, no refund, row transferred.
func TestStripeWithdrawAmbiguousTransferRetryRecovers(t *testing.T) {
	fakeStripe := droppingStripe(t, "/v1/transfers", 1, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/transfers" && r.Method == http.MethodPost {
			_, _ = w.Write([]byte(`{"id":"tr_recovered","amount":500,"destination":"acct_x","created":1}`))
			return
		}
	})
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-ambig-rec", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (exactly one debit)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 || wds[0].Status != "transferred" || wds[0].TransferID != "tr_recovered" {
		t.Errorf("row = %+v, want transferred with tr_recovered", wds[0])
	}
}


// TestStripeWithdrawAmbiguousInstantPayoutKeepsFee: when payouts.create times
// out, the payout may exist (user gets instant delivery) — the fee must NOT
// be refunded and the row must stay observable (transferred, no payout ID).
func TestStripeWithdrawAmbiguousInstantPayoutKeepsFee(t *testing.T) {
	fakeStripe := droppingStripe(t, "/v1/payouts", 99, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v1/transfers" && r.Method == http.MethodPost {
			_, _ = w.Write([]byte(`{"id":"tr_ambig_po","amount":450,"destination":"acct_x","created":1}`))
			return
		}
	})
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-ambig-po", "alice@example.com", true)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"instant"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusAccepted {
		t.Fatalf("got %d, want 202: %s", w.Code, w.Body.String())
	}
	// Gross debited, fee NOT refunded (payout may have delivered).
	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance = %d, want 5_000_000 (fee kept until outcome is known)", bal)
	}
	wds, _ := st.ListStripeWithdrawals(user.AccountID, 0)
	if len(wds) != 1 {
		t.Fatalf("want 1 withdrawal row, got %d", len(wds))
	}
	wd := wds[0]
	if wd.Status != "transferred" || wd.PayoutID != "" || wd.FeeRefunded {
		t.Errorf("row = status %q payout %q feeRefunded=%v, want transferred/empty/false", wd.Status, wd.PayoutID, wd.FeeRefunded)
	}
	if !strings.Contains(wd.FailureReason, "instant_payout_unconfirmed") {
		t.Errorf("failure reason = %q, want instant_payout_unconfirmed", wd.FailureReason)
	}
}


