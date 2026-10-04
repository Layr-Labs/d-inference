package billing_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// --- Withdrawal with non-withdrawable balance ---

func TestStripeWithdrawRejectsNonWithdrawableBalance(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-nw-1", "alice@example.com", false)
	st.Credit(user.AccountID, 10_000_000, store.LedgerStripeDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
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
	if errObj["type"] != "insufficient_withdrawable" {
		t.Errorf("error type = %v, want insufficient_withdrawable", errObj["type"])
	}
}

func TestStripeWithdrawAllowsWithdrawableBalance(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-aw-1", "alice@example.com", false)
	st.Credit(user.AccountID, 5_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerPayout, "earning")

	body := `{"amount_usd":"8.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	if bal := st.GetBalance(user.AccountID); bal != 7_000_000 {
		t.Errorf("balance = %d, want 7_000_000", bal)
	}
}

func TestStripeWithdrawRejectsExceedingWithdrawable(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-ex-1", "alice@example.com", false)
	st.Credit(user.AccountID, 10_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 5_000_000, store.LedgerPayout, "earning")

	body := `{"amount_usd":"8.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400 (only $5 withdrawable): %s", w.Code, w.Body.String())
	}
}

// --- Admin credit endpoint ---

func TestAdminCreditNonWithdrawable(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")
	user := seedUser(t, st, "acct-ac-1", "alice@example.com")

	body := `{"email":"alice@example.com","amount_usd":"25.00","note":"welcome bonus"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["withdrawable"] != false {
		t.Errorf("admin credit should be non-withdrawable")
	}
	if bal := st.GetBalance(user.AccountID); bal != 25_000_000 {
		t.Errorf("balance = %d, want 25_000_000", bal)
	}
	if wd := st.GetWithdrawableBalance(user.AccountID); wd != 0 {
		t.Errorf("withdrawable = %d, want 0 (admin credit is non-withdrawable)", wd)
	}

	entries := st.LedgerHistory(user.AccountID)
	if len(entries) != 1 {
		t.Fatalf("expected 1 ledger entry, got %d", len(entries))
	}
	if entries[0].Type != store.LedgerAdminCredit {
		t.Errorf("entry type = %q, want admin_credit", entries[0].Type)
	}
}

func TestAdminCreditRejectsNonAdmin(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")
	seedUser(t, st, "acct-ac-2", "bob@example.com")

	body := `{"email":"bob@example.com","amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+srv.sessions.Token("acct-ac-2"))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("got %d, want 403", w.Code)
	}
}

func TestAdminCreditUnknownEmail(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")

	body := `{"email":"nobody@example.com","amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("got %d, want 404", w.Code)
	}
}

// --- Admin reward endpoint ---

func TestAdminRewardWithdrawable(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")
	user := seedUser(t, st, "acct-ar-1", "provider@example.com")

	body := `{"email":"provider@example.com","amount_usd":"50.00","note":"bonus payout"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/reward", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["withdrawable"] != true {
		t.Errorf("admin reward should be withdrawable")
	}
	if bal := st.GetBalance(user.AccountID); bal != 50_000_000 {
		t.Errorf("balance = %d, want 50_000_000", bal)
	}
	if wd := st.GetWithdrawableBalance(user.AccountID); wd != 50_000_000 {
		t.Errorf("withdrawable = %d, want 50_000_000", wd)
	}

	entries := st.LedgerHistory(user.AccountID)
	if len(entries) != 1 {
		t.Fatalf("expected 1 ledger entry, got %d", len(entries))
	}
	if entries[0].Type != store.LedgerAdminReward {
		t.Errorf("entry type = %q, want admin_reward", entries[0].Type)
	}
}

func TestAdminRewardRejectsNonAdmin(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")
	seedUser(t, st, "acct-ar-2", "bob@example.com")

	body := `{"email":"bob@example.com","amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/reward", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+srv.sessions.Token("acct-ar-2"))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("got %d, want 403", w.Code)
	}
}

// --- Admin reward → withdraw end-to-end ---

func TestAdminRewardThenWithdraw(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")
	user := readyUser(t, st, "acct-e2e-1", "provider@example.com", false)

	// Admin rewards $20
	body := `{"email":"provider@example.com","amount_usd":"20.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/reward", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("reward: got %d: %s", w.Code, w.Body.String())
	}

	// Withdraw $15 — should succeed
	body = `{"amount_usd":"15.00","method":"standard"}`
	req = httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w = httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("withdraw: got %d: %s", w.Code, w.Body.String())
	}

	if bal := st.GetBalance(user.AccountID); bal != 5_000_000 {
		t.Errorf("balance after = %d, want 5_000_000", bal)
	}
	if wd := st.GetWithdrawableBalance(user.AccountID); wd != 5_000_000 {
		t.Errorf("withdrawable after = %d, want 5_000_000", wd)
	}
}

// --- Withdrawal refund restores withdrawable ---

func TestStripeWithdrawFailureRestoresWithdrawable(t *testing.T) {
	fakeStripe := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":{"message":"boom","type":"invalid_request_error"}}`))
	}))
	defer fakeStripe.Close()

	srv, st := stripePayoutsTestServer(t, false, fakeStripe)
	user := readyUser(t, st, "acct-refund-1", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerPayout, "earning")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadGateway {
		t.Fatalf("got %d, want 502", w.Code)
	}
	// Balance and withdrawable should both be fully restored
	if bal := st.GetBalance(user.AccountID); bal != 10_000_000 {
		t.Errorf("balance after refund = %d, want 10_000_000", bal)
	}
	if wd := st.GetWithdrawableBalance(user.AccountID); wd != 10_000_000 {
		t.Errorf("withdrawable after refund = %d, want 10_000_000 (should be restored)", wd)
	}
}

// --- Admin endpoint validation ---

func TestAdminCreditMissingEmail(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")

	body := `{"amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 for missing email", w.Code)
	}
}

func TestAdminCreditInvalidAmount(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")
	seedUser(t, st, "acct-inv-1", "alice@example.com")

	body := `{"email":"alice@example.com","amount_usd":"-5.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 for negative amount", w.Code)
	}
}

func TestAdminRewardMissingEmail(t *testing.T) {
	srv, _ := stripePayoutsTestServer(t, true, nil)
	srv.SetAdminKey("admin-secret")

	body := `{"amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/reward", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 for missing email", w.Code)
	}
}

// --- Balance endpoint includes withdrawable ---

func TestBalanceEndpointIncludesWithdrawable(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := seedUser(t, st, "acct-bal-1", "alice@example.com")
	st.Credit(user.AccountID, 20_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 30_000_000, store.LedgerPayout, "earning")

	req := httptest.NewRequest(http.MethodGet, "/v1/payments/balance", nil)
	req = srv.withUser(req, user)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if bal, _ := resp["balance_micro_usd"].(float64); int64(bal) != 50_000_000 {
		t.Errorf("balance_micro_usd = %v, want 50_000_000", resp["balance_micro_usd"])
	}
	if wd, _ := resp["withdrawable_micro_usd"].(float64); int64(wd) != 30_000_000 {
		t.Errorf("withdrawable_micro_usd = %v, want 30_000_000", resp["withdrawable_micro_usd"])
	}
}
