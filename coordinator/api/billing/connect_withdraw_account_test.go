package billing

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
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
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeWithdraw(w, req)

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
