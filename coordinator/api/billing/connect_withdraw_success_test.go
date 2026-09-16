package billing

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestStripeWithdrawStandardSuccess(t *testing.T) {
	srv, st := stripePayoutsTestServer(t, true, nil)
	user := readyUser(t, st, "acct-w-std", "alice@example.com", false)
	st.CreditWithdrawable(user.AccountID, 10_000_000, store.LedgerDeposit, "seed")

	body := `{"amount_usd":"5.00","method":"standard"}`
	req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/stripe", strings.NewReader(body))
	req = withPrivyUser(req, user)
	w := httptest.NewRecorder()
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
	srv.StripeWithdraw(w, req)

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
