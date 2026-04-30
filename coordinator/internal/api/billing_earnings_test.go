package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/darkbloom/coordinator/internal/store"
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

type nodeEarningsResponse struct {
	ProviderKey   string                  `json:"provider_key"`
	Earnings      []store.ProviderEarning `json:"earnings"`
	TotalMicroUSD int64                   `json:"total_micro_usd"`
	TotalUSD      string                  `json:"total_usd"`
	Count         int64                   `json:"count"`
	RecentCount   int                     `json:"recent_count"`
	HistoryLimit  int                     `json:"history_limit"`
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

func TestNodeEarningsUsesLifetimeTotalsInsteadOfLimitedSlice(t *testing.T) {
	srv, st := testWithdrawServer(t)

	now := time.Now()
	entries := []store.ProviderEarning{
		{
			AccountID:      "acct-1",
			ProviderID:     "node-1",
			ProviderKey:    "provider-key-1",
			JobID:          "job-1",
			Model:          "model-a",
			AmountMicroUSD: 300_000,
			CreatedAt:      now.Add(-2 * time.Minute),
		},
		{
			AccountID:      "acct-1",
			ProviderID:     "node-1",
			ProviderKey:    "provider-key-1",
			JobID:          "job-2",
			Model:          "model-a",
			AmountMicroUSD: 200_000,
			CreatedAt:      now.Add(-1 * time.Minute),
		},
		{
			AccountID:      "acct-2",
			ProviderID:     "node-2",
			ProviderKey:    "provider-key-2",
			JobID:          "job-3",
			Model:          "model-b",
			AmountMicroUSD: 999_000,
			CreatedAt:      now,
		},
	}
	for _, entry := range entries {
		if err := st.RecordProviderEarning(&entry); err != nil {
			t.Fatalf("record provider earning: %v", err)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=provider-key-1&limit=1", nil)
	w := httptest.NewRecorder()

	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}

	var resp nodeEarningsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}

	if resp.ProviderKey != "provider-key-1" {
		t.Fatalf("provider_key = %q, want provider-key-1", resp.ProviderKey)
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
	if len(resp.Earnings) != 1 {
		t.Fatalf("earnings length = %d, want 1", len(resp.Earnings))
	}
	if resp.Earnings[0].JobID != "job-2" {
		t.Fatalf("latest earning job_id = %q, want job-2", resp.Earnings[0].JobID)
	}
}
