package billing_test

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestHTTPViewsShareConfiguredLedgerAndStore(t *testing.T) {
	fixture := testkit.New(t, api.ServerConfig{})
	st := fixture.Store
	account := store.LegacyAccountID("test-key")
	ledger := payments.NewLedger(st)
	fixture.Server.SetBilling(billing.NewService(st, ledger, slog.New(slog.DiscardHandler), billing.Config{MockMode: true}))
	if err := st.CreditWithdrawable(account, 1_500_000, store.LedgerPayout, "earned"); err != nil {
		t.Fatal(err)
	}
	st.RecordUsage(store.UsageRecord{ConsumerKey: account, RequestID: "request",
		Model: "build", PublicModel: "public", CostMicroUSD: 42, CompletionTokens: 7})
	server := httptest.NewServer(fixture.Server.Handler())
	t.Cleanup(server.Close)
	get := func(path string, out any) {
		t.Helper()
		req, err := http.NewRequest(http.MethodGet, server.URL+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer test-key")
		resp, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("%s: HTTP %d", path, resp.StatusCode)
		}
		if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
			t.Fatal(err)
		}
	}
	var balance types.BalanceResponse
	get("/v1/payments/balance", &balance)
	if balance.BalanceMicroUSD != 1_500_000 || balance.WithdrawableMicroUSD != 1_500_000 {
		t.Fatalf("balance did not use the configured store: %+v", balance)
	}
	var wallet map[string]int64
	get("/v1/billing/wallet/balance", &wallet)
	if wallet["credit_balance_micro_usd"] != balance.BalanceMicroUSD {
		t.Fatalf("wallet and ledger disagree: %+v", wallet)
	}
	var usage types.UsageResponse
	get("/v1/payments/usage", &usage)
	if len(usage.Usage) != 1 || usage.Usage[0].Model != "public" || usage.Usage[0].CostMicroUSD != 42 {
		t.Fatalf("persisted usage fallback changed: %+v", usage)
	}
}
