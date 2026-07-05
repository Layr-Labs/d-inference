package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestProviderEarningsEndpoint verifies the /v1/provider/earnings endpoint
// returns balance and payout info for a provider wallet address.
func TestProviderEarningsEndpoint(t *testing.T) {
	srv, st := testServer(t)

	// Credit a provider wallet directly (simulates inference completion flow)
	providerWallet := "0xProviderWallet1234567890abcdef1234567890"
	_ = st.Credit(providerWallet, 450_000, store.LedgerPayout, "job-1") // $0.45
	_ = st.Credit(providerWallet, 900_000, store.LedgerPayout, "job-2") // $0.90

	// Query earnings — no auth required
	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet="+providerWallet, nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	// Balance should be 450,000 + 900,000 = 1,350,000 micro-USD
	balance := resp["balance_micro_usd"].(float64)
	if balance != 1_350_000 {
		t.Errorf("balance_micro_usd = %v, want 1350000", balance)
	}

	balanceUSD := resp["balance_usd"].(string)
	if balanceUSD != "1.350000" {
		t.Errorf("balance_usd = %v, want 1.350000", balanceUSD)
	}

	// Should have ledger entries
	ledger := resp["ledger"].([]any)
	if len(ledger) != 2 {
		t.Errorf("ledger entries = %d, want 2", len(ledger))
	}
}

func TestProviderEarningsUsesStoredPayoutRecords(t *testing.T) {
	srv, _ := testServer(t)

	wallet := "0xStoredPayoutWallet1234567890abcdef1234"
	if err := srv.store.CreditProviderWallet(&store.ProviderPayout{
		ProviderAddress: wallet,
		AmountMicroUSD:  250_000,
		Model:           "qwen3.5-9b",
		JobID:           "job-stored",
	}); err != nil {
		t.Fatalf("CreditProviderWallet: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet="+wallet, nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200, body = %s", w.Code, w.Body.String())
	}

	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	payouts, ok := resp["payouts"].([]any)
	if !ok || len(payouts) != 1 {
		t.Fatalf("payouts = %#v, want single payout", resp["payouts"])
	}

	payout, ok := payouts[0].(map[string]any)
	if !ok {
		t.Fatalf("payout = %#v, want object", payouts[0])
	}
	if payout["model"] != "qwen3.5-9b" {
		t.Errorf("payout model = %v, want qwen3.5-9b", payout["model"])
	}
	if settled, _ := payout["settled"].(bool); settled {
		t.Errorf("payout settled = %v, want false", payout["settled"])
	}
}

func TestProviderEarningsNoWallet(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestProviderEarningsViaHeader(t *testing.T) {
	srv, st := testServer(t)

	wallet := "0xHeaderWallet0000000000000000000000000000"
	_ = st.Credit(wallet, 100_000, store.LedgerPayout, "job-h1")

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings", nil)
	req.Header.Set("X-Provider-Wallet", wallet)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["balance_micro_usd"].(float64) != 100_000 {
		t.Errorf("balance_micro_usd = %v, want 100000", resp["balance_micro_usd"])
	}
}

func TestProviderEarningsEmptyWallet(t *testing.T) {
	srv, _ := testServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/earnings?wallet=0xNewWallet", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)

	if resp["balance_micro_usd"].(float64) != 0 {
		t.Errorf("balance_micro_usd = %v, want 0", resp["balance_micro_usd"])
	}
	if resp["total_jobs"].(float64) != 0 {
		t.Errorf("total_jobs = %v, want 0", resp["total_jobs"])
	}
}
