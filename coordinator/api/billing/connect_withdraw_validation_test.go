package billing

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStripeWithdrawRejectsWithoutOnboarding(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-w-1", "alice@example.com")
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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

func TestStripeWithdrawInsufficientBalance(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-poor", "alice@example.com", false)
	// No credit seeded.

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeWithdraw(w, req)

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

// TestStripeWithdrawRejectsExceedingWithdrawableViaDebit verifies that the
// DebitWithdrawable path rejects a withdrawal that exceeds the withdrawable
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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeWithdraw(w, req)

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
