package billing_test

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestStripeWithdrawRejectsWithoutOnboarding(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-w-1", "alice@example.com")
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})

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
	srv := newBillingFixture(t, reg, st, api.ServerConfig{}, logger)
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
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

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

// TestStripeWithdrawRejectsExceedingWithdrawableViaDebit verifies that the
// guarded withdrawal debit rejects a withdrawal that exceeds the withdrawable
// balance even when total balance is sufficient.
func TestStripeWithdrawRejectsExceedingWithdrawableViaDebit(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-debit-guard", "guard@example.com", false)

	// $100 total but only $20 withdrawable.
	st.Credit(user.AccountID, 80_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 20_000_000, store.LedgerPayout, "earnings")

	// Try to withdraw $30 — total balance is $100 but withdrawable is only $20.
	body := `{"amount_usd":"30.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400; body: %s", w.Code, w.Body.String())
	}

	// Balances should be untouched.
	if bal := st.GetBalance(user.AccountID); bal != 100_000_000 {
		t.Errorf("balance = %d, want 100_000_000 (unchanged)", bal)
	}
	if wd := st.GetWithdrawableBalance(user.AccountID); wd != 20_000_000 {
		t.Errorf("withdrawable = %d, want 20_000_000 (unchanged)", wd)
	}
}
