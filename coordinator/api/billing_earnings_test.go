package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type accountEarningsResponse struct {
	AccountID                string                  `json:"account_id"`
	Earnings                 []store.ProviderEarning `json:"earnings"`
	TotalMicroUSD            int64                   `json:"total_micro_usd"`
	TotalUSD                 string                  `json:"total_usd"`
	Count                    int64                   `json:"count"`
	RecentCount              int                     `json:"recent_count"`
	HistoryLimit             int                     `json:"history_limit"`
	AvailableBalanceMicroUSD int64                   `json:"available_balance_micro_usd"`
	AvailableBalanceUSD      string                  `json:"available_balance_usd"`
}

func TestAccountEarningsUsesLifetimeTotalsAndCurrentBalance(t *testing.T) {
	srv, st := testWithdrawServer(t)

	accountID := "acct-provider-earnings"
	now := time.Now()
	entries := []store.ProviderEarning{
		{
			AccountID:      accountID,
			ProviderID:     "node-1",
			ProviderKey:    "provider-key-1",
			JobID:          "job-1",
			Model:          "mlx-community/Qwen3.5-9B-MLX-4bit",
			AmountMicroUSD: 300_000,
			CreatedAt:      now.Add(-2 * time.Minute),
		},
		{
			AccountID:      accountID,
			ProviderID:     "node-2",
			ProviderKey:    "provider-key-2",
			JobID:          "job-2",
			Model:          "mlx-community/Qwen3.5-9B-MLX-4bit",
			AmountMicroUSD: 200_000,
			CreatedAt:      now.Add(-1 * time.Minute),
		},
	}
	for _, entry := range entries {
		if err := st.CreditProviderAccount(&entry); err != nil {
			t.Fatalf("credit provider account: %v", err)
		}
	}
	if err := st.Debit(accountID, 100_000, store.LedgerWithdrawal, "claim-1"); err != nil {
		t.Fatalf("debit balance: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/account-earnings?limit=1", nil)
	req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, accountID))
	w := httptest.NewRecorder()

	srv.handleAccountEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}

	var resp accountEarningsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}

	if resp.AccountID != accountID {
		t.Fatalf("account_id = %q, want %q", resp.AccountID, accountID)
	}
	if resp.TotalMicroUSD != 500_000 {
		t.Fatalf("total_micro_usd = %d, want 500000", resp.TotalMicroUSD)
	}
	if resp.TotalUSD != "0.500000" {
		t.Fatalf("total_usd = %q, want 0.500000", resp.TotalUSD)
	}
	if resp.Count != 2 {
		t.Fatalf("count = %d, want 2", resp.Count)
	}
	if resp.RecentCount != 1 {
		t.Fatalf("recent_count = %d, want 1", resp.RecentCount)
	}
	if resp.HistoryLimit != 1 {
		t.Fatalf("history_limit = %d, want 1", resp.HistoryLimit)
	}
	if resp.AvailableBalanceMicroUSD != 400_000 {
		t.Fatalf("available_balance_micro_usd = %d, want 400000", resp.AvailableBalanceMicroUSD)
	}
	if resp.AvailableBalanceUSD != "0.400000" {
		t.Fatalf("available_balance_usd = %q, want 0.400000", resp.AvailableBalanceUSD)
	}
	if len(resp.Earnings) != 1 {
		t.Fatalf("earnings length = %d, want 1", len(resp.Earnings))
	}
	if resp.Earnings[0].JobID != "job-2" {
		t.Fatalf("latest earning job_id = %q, want job-2", resp.Earnings[0].JobID)
	}
}

func TestAccountEarningsGroupsByMachine(t *testing.T) {
	srv, st := testWithdrawServer(t)

	accountID := "acct-by-machine"
	now := time.Now()

	// Machine 1 has a provider record (hardware label available); machine 2
	// has none (e.g. unlinked); the empty key simulates rows recorded before
	// provider_key existed.
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:        "session-uuid-1",
		AccountID: accountID,
		PublicKey: "machine-key-1",
		Hardware:  json.RawMessage(`{"chip_name":"Apple M4 Max","memory_gb":64}`),
	}); err != nil {
		t.Fatalf("upsert provider: %v", err)
	}

	entries := []store.ProviderEarning{
		{AccountID: accountID, ProviderID: "conn-1", ProviderKey: "machine-key-1", JobID: "job-1",
			Model: "qwen3.5-35b-a3b", AmountMicroUSD: 300_000, PromptTokens: 100, CompletionTokens: 50,
			CreatedAt: now.Add(-3 * time.Minute)},
		{AccountID: accountID, ProviderID: "conn-2", ProviderKey: "machine-key-1", JobID: "job-2",
			Model: "base_reward", AmountMicroUSD: 40_000, CreatedAt: now.Add(-2 * time.Minute)},
		{AccountID: accountID, ProviderID: "conn-3", ProviderKey: "machine-key-2", JobID: "job-3",
			Model: "qwen3.5-35b-a3b", AmountMicroUSD: 200_000, PromptTokens: 80, CompletionTokens: 40,
			CreatedAt: now.Add(-1 * time.Minute)},
		{AccountID: accountID, ProviderID: "conn-4", ProviderKey: "", JobID: "job-4",
			Model: "qwen3.5-35b-a3b", AmountMicroUSD: 10_000, CreatedAt: now.Add(-4 * time.Minute)},
	}
	for _, entry := range entries {
		if err := st.CreditProviderAccount(&entry); err != nil {
			t.Fatalf("credit provider account: %v", err)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/account-earnings?limit=10", nil)
	req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, accountID))
	w := httptest.NewRecorder()
	srv.handleAccountEarnings(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}

	var resp struct {
		ByProvider []struct {
			ProviderKey      string `json:"provider_key"`
			ChipName         string `json:"chip_name"`
			MemoryGB         int    `json:"memory_gb"`
			TotalMicroUSD    int64  `json:"total_micro_usd"`
			TotalUSD         string `json:"total_usd"`
			JobCount         int64  `json:"job_count"`
			PromptTokens     int64  `json:"prompt_tokens"`
			CompletionTokens int64  `json:"completion_tokens"`
		} `json:"by_provider"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}

	if len(resp.ByProvider) != 3 {
		t.Fatalf("by_provider length = %d, want 3: %s", len(resp.ByProvider), w.Body.String())
	}

	// Highest total first: machine-1 (300k inference + 40k base reward).
	m1 := resp.ByProvider[0]
	if m1.ProviderKey != "machine-key-1" {
		t.Fatalf("first machine = %q, want machine-key-1", m1.ProviderKey)
	}
	if m1.TotalMicroUSD != 340_000 || m1.TotalUSD != "0.340000" {
		t.Fatalf("machine-1 total = %d/%q, want 340000/0.340000", m1.TotalMicroUSD, m1.TotalUSD)
	}
	if m1.JobCount != 1 {
		t.Fatalf("machine-1 job_count = %d, want 1 (base_reward rows are not jobs)", m1.JobCount)
	}
	if m1.PromptTokens != 100 || m1.CompletionTokens != 50 {
		t.Fatalf("machine-1 tokens = %d/%d, want 100/50", m1.PromptTokens, m1.CompletionTokens)
	}
	if m1.ChipName != "Apple M4 Max" || m1.MemoryGB != 64 {
		t.Fatalf("machine-1 hardware = %q/%d, want Apple M4 Max/64", m1.ChipName, m1.MemoryGB)
	}

	// Machine 2 has no provider record: aggregates present, hardware empty.
	m2 := resp.ByProvider[1]
	if m2.ProviderKey != "machine-key-2" || m2.TotalMicroUSD != 200_000 {
		t.Fatalf("second machine = %q/%d, want machine-key-2/200000", m2.ProviderKey, m2.TotalMicroUSD)
	}
	if m2.ChipName != "" || m2.MemoryGB != 0 {
		t.Fatalf("machine-2 hardware should be empty, got %q/%d", m2.ChipName, m2.MemoryGB)
	}

	// Legacy rows (no provider_key) aggregate under the empty key.
	m3 := resp.ByProvider[2]
	if m3.ProviderKey != "" || m3.TotalMicroUSD != 10_000 {
		t.Fatalf("third bucket = %q/%d, want empty-key/10000", m3.ProviderKey, m3.TotalMicroUSD)
	}
}
