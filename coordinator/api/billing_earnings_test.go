package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	apitypes "github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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

	var resp apitypes.AccountEarningsResponse
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

func TestAccountEarningsProviderTokenReturnsCompleteLinkedHistory(t *testing.T) {
	srv, st := testWithdrawServer(t)
	const (
		accountID   = "acct-linked-history"
		rawToken    = "eigeninference-pt-linked-history"
		providerID  = "provider-session-1"
		providerKey = "provider-key-1"
	)

	tokenHash := sha256.Sum256([]byte(rawToken))
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: fmt.Sprintf("%x", tokenHash[:]),
		AccountID: accountID,
		Active:    true,
	}); err != nil {
		t.Fatalf("create provider token: %v", err)
	}
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:           providerID,
		AccountID:    accountID,
		PublicKey:    providerKey,
		SerialNumber: "SERIAL-1",
		LastSeen:     time.Now(),
	}); err != nil {
		t.Fatalf("upsert provider: %v", err)
	}
	if err := st.CreditProviderAccount(&store.ProviderEarning{
		AccountID:        accountID,
		ProviderID:       providerID,
		ProviderKey:      providerKey,
		JobID:            "job-linked",
		Model:            "qwen3.5-9b",
		AmountMicroUSD:   300_000,
		PromptTokens:     120,
		CompletionTokens: 45,
		CreatedAt:        time.Now().Add(-time.Minute),
	}); err != nil {
		t.Fatalf("credit provider account: %v", err)
	}
	if credited, err := st.SettleProviderFloorDraw(context.Background(), &store.ProviderFloorDraw{
		ProviderKey:    providerKey,
		AccountID:      accountID,
		EpochID:        "2026-08",
		AmountMicroUSD: 450_000,
		FloorMicroUSD:  450_000,
		UptimeFrac:     1,
		MemoryGB:       64,
		CreatedAt:      time.Now(),
	}); err != nil || !credited {
		t.Fatalf("settle floor draw: credited=%v err=%v", credited, err)
	}

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	req, err := http.NewRequest(
		http.MethodGet,
		ts.URL+"/v1/provider/account-earnings?limit=10",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+rawToken)
	response, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("account earnings request: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", response.StatusCode)
	}

	var payload apitypes.AccountEarningsResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload.AccountID != accountID {
		t.Fatalf("account_id = %q, want %q", payload.AccountID, accountID)
	}
	if payload.TotalMicroUSD != 750_000 || payload.Count != 1 {
		t.Fatalf("summary = (%d, %d), want (750000, 1)", payload.TotalMicroUSD, payload.Count)
	}
	if len(payload.Earnings) != 2 {
		t.Fatalf("earnings length = %d, want 2", len(payload.Earnings))
	}
	var inference, floor *store.ProviderEarning
	for i := range payload.Earnings {
		switch payload.Earnings[i].Model {
		case "qwen3.5-9b":
			inference = &payload.Earnings[i]
		case "base_reward":
			floor = &payload.Earnings[i]
		}
	}
	if inference == nil || inference.PromptTokens != 120 || inference.CompletionTokens != 45 {
		t.Fatalf("inference earning missing token detail: %+v", inference)
	}
	if floor == nil || floor.AmountMicroUSD != 450_000 {
		t.Fatalf("base reward missing from history: %+v", floor)
	}
	if len(payload.Providers) != 1 {
		t.Fatalf("providers length = %d, want 1", len(payload.Providers))
	}
	if got := payload.Providers[0]; got.ProviderID != providerID ||
		got.ProviderKey != providerKey || got.SerialNumber != "SERIAL-1" {
		t.Fatalf("provider identity = %+v", got)
	}
}
