package api

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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("got %d, want 400 (only $5 withdrawable): %s", w.Code, w.Body.String())
	}
}

// --- Admin credit endpoint ---

func TestAdminCreditNonWithdrawable(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-secret")
	user := seedUser(t, st, "acct-ac-1", "alice@example.com")

	body := `{"email":"alice@example.com","amount_usd":"25.00","note":"welcome bonus"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.handleAdminCredit(w, req)

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
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-secret")
	seedUser(t, st, "acct-ac-2", "bob@example.com")

	body := `{"email":"bob@example.com","amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	w := httptest.NewRecorder()
	srv.handleAdminCredit(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("got %d, want 403", w.Code)
	}
}

func TestAdminCreditUnknownEmail(t *testing.T) {
	srv, _ := testBillingServer(t)
	srv.SetAdminKey("admin-secret")

	body := `{"email":"nobody@example.com","amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.handleAdminCredit(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("got %d, want 404", w.Code)
	}
}

// --- Admin reward endpoint ---

func TestAdminRewardWithdrawable(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-secret")
	user := seedUser(t, st, "acct-ar-1", "provider@example.com")

	body := `{"email":"provider@example.com","amount_usd":"50.00","note":"bonus payout"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/reward", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.handleAdminReward(w, req)

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
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-secret")
	seedUser(t, st, "acct-ar-2", "bob@example.com")

	body := `{"email":"bob@example.com","amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/reward", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer wrong-key")
	w := httptest.NewRecorder()
	srv.handleAdminReward(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("got %d, want 403", w.Code)
	}
}

func TestAdminBillingRejectsInvalidAmountsWithoutMutation(t *testing.T) {
	handlers := []struct {
		name   string
		path   string
		handle func(*Server, http.ResponseWriter, *http.Request)
	}{
		{name: "credit", path: "/v1/admin/credit", handle: (*Server).handleAdminCredit},
		{name: "reward", path: "/v1/admin/reward", handle: (*Server).handleAdminReward},
	}
	amounts := []struct {
		name  string
		value string
	}{
		{name: "nan", value: "NaN"},
		{name: "positive_infinity", value: "+Inf"},
		{name: "negative_infinity", value: "-Inf"},
		{name: "zero", value: "0"},
		{name: "negative", value: "-1"},
		{name: "sub_micro", value: "0.0000009"},
		{name: "int64_overflow", value: "9223372036854.776"},
		{name: "large_finite_overflow", value: "1e308"},
	}

	for _, handler := range handlers {
		for _, amount := range amounts {
			t.Run(handler.name+"/"+amount.name, func(t *testing.T) {
				srv, st := testBillingServer(t)
				srv.SetAdminKey("admin-secret")
				user := seedUser(t, st, "acct-amount-validation", "amount-validation@example.com")

				body := `{"email":"amount-validation@example.com","amount_usd":"` + amount.value + `"}`
				req := httptest.NewRequest(http.MethodPost, handler.path, strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer admin-secret")
				w := httptest.NewRecorder()
				handler.handle(srv, w, req)

				if w.Code != http.StatusBadRequest {
					t.Fatalf("got %d, want 400: %s", w.Code, w.Body.String())
				}
				var resp struct {
					Error struct {
						Type    string `json:"type"`
						Message string `json:"message"`
						Code    string `json:"code"`
					} `json:"error"`
				}
				if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
					t.Fatalf("decode response: %v", err)
				}
				if resp.Error.Type != "invalid_request_error" ||
					resp.Error.Code != "invalid_request_error" ||
					resp.Error.Message != "amount_usd must be a positive number" {
					t.Fatalf("unexpected error response: %#v", resp.Error)
				}
				if balance := st.GetBalance(user.AccountID); balance != 0 {
					t.Errorf("balance mutated to %d", balance)
				}
				if withdrawable := st.GetWithdrawableBalance(user.AccountID); withdrawable != 0 {
					t.Errorf("withdrawable balance mutated to %d", withdrawable)
				}
				if entries := st.LedgerHistory(user.AccountID); len(entries) != 0 {
					t.Errorf("ledger mutated with %d entries", len(entries))
				}
			})
		}
	}
}

func TestAdminBillingAcceptsPositiveMicroAmounts(t *testing.T) {
	handlers := []struct {
		name         string
		path         string
		handle       func(*Server, http.ResponseWriter, *http.Request)
		withdrawable bool
	}{
		{name: "credit", path: "/v1/admin/credit", handle: (*Server).handleAdminCredit},
		{name: "reward", path: "/v1/admin/reward", handle: (*Server).handleAdminReward, withdrawable: true},
	}
	amounts := []struct {
		name         string
		value        string
		wantMicroUSD int64
	}{
		{name: "exact_minimum", value: "0.000001", wantMicroUSD: 1},
		{name: "ordinary", value: "1.25", wantMicroUSD: 1_250_000},
	}

	for _, handler := range handlers {
		for _, amount := range amounts {
			t.Run(handler.name+"/"+amount.name, func(t *testing.T) {
				srv, st := testBillingServer(t)
				srv.SetAdminKey("admin-secret")
				user := seedUser(t, st, "acct-finite-amount", "finite-amount@example.com")

				body := `{"email":"finite-amount@example.com","amount_usd":"` + amount.value + `"}`
				req := httptest.NewRequest(http.MethodPost, handler.path, strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer admin-secret")
				w := httptest.NewRecorder()
				handler.handle(srv, w, req)

				if w.Code != http.StatusOK {
					t.Fatalf("got %d, want 200: %s", w.Code, w.Body.String())
				}
				if balance := st.GetBalance(user.AccountID); balance != amount.wantMicroUSD {
					t.Errorf("balance = %d, want %d", balance, amount.wantMicroUSD)
				}
				wantWithdrawable := int64(0)
				if handler.withdrawable {
					wantWithdrawable = amount.wantMicroUSD
				}
				if withdrawable := st.GetWithdrawableBalance(user.AccountID); withdrawable != wantWithdrawable {
					t.Errorf("withdrawable balance = %d, want %d", withdrawable, wantWithdrawable)
				}
				entries := st.LedgerHistory(user.AccountID)
				if len(entries) != 1 {
					t.Fatalf("ledger entries = %d, want 1", len(entries))
				}
				if entries[0].AmountMicroUSD != amount.wantMicroUSD {
					t.Errorf("ledger amount = %d, want %d", entries[0].AmountMicroUSD, amount.wantMicroUSD)
				}
			})
		}
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
	srv.handleAdminReward(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("reward: got %d: %s", w.Code, w.Body.String())
	}

	// Withdraw $15 — should succeed
	body = `{"amount_usd":"15.00","method":"standard"}`
	req = httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w = httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)
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
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleStripeWithdraw(w, req)

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
	srv, _ := testBillingServer(t)
	srv.SetAdminKey("admin-secret")

	body := `{"amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.handleAdminCredit(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 for missing email", w.Code)
	}
}

func TestAdminCreditInvalidAmount(t *testing.T) {
	srv, st := testBillingServer(t)
	srv.SetAdminKey("admin-secret")
	seedUser(t, st, "acct-inv-1", "alice@example.com")

	body := `{"email":"alice@example.com","amount_usd":"-5.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/credit", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.handleAdminCredit(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 for negative amount", w.Code)
	}
}

func TestAdminRewardMissingEmail(t *testing.T) {
	srv, _ := testBillingServer(t)
	srv.SetAdminKey("admin-secret")

	body := `{"amount_usd":"10.00"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/admin/reward", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer admin-secret")
	w := httptest.NewRecorder()
	srv.handleAdminReward(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("got %d, want 400 for missing email", w.Code)
	}
}

// --- Balance endpoint includes withdrawable ---

func TestBalanceEndpointIncludesWithdrawable(t *testing.T) {
	srv, st := testBillingServer(t)
	user := seedUser(t, st, "acct-bal-1", "alice@example.com")
	st.Credit(user.AccountID, 20_000_000, store.LedgerStripeDeposit, "deposit")
	st.CreditWithdrawable(user.AccountID, 30_000_000, store.LedgerPayout, "earning")

	req := httptest.NewRequest(http.MethodGet, "/v1/payments/balance", nil)
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.handleBalance(w, req)

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
