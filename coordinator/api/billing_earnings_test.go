package api

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
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
	// Ownership is resolved from the persisted record by public key.
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID: "node-1", AccountID: "acct-1", PublicKey: "provider-key-1",
	}); err != nil {
		t.Fatalf("upsert provider (ownership): %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=provider-key-1&limit=1", nil)
	// acct-1 owns provider-key-1 — node-earnings is now ownership-scoped.
	req = withPrivyUser(req, &store.User{AccountID: "acct-1"})
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

// seedNodeEarning is a small helper for the node-earnings auth tests.
// It records an earning AND persists a ProviderRecord linking the account to the
// X25519 key, since node-earnings ownership is now resolved from the registry /
// persisted record by public key (not by sampling an earnings row).
func seedNodeEarning(t *testing.T, st *store.MemoryStore, accountID, providerKey, jobID string, amount int64) {
	t.Helper()
	if err := st.RecordProviderEarning(&store.ProviderEarning{
		AccountID:      accountID,
		ProviderID:     "node-" + providerKey,
		ProviderKey:    providerKey,
		JobID:          jobID,
		Model:          "model-a",
		AmountMicroUSD: amount,
		CreatedAt:      time.Now(),
	}); err != nil {
		t.Fatalf("record provider earning: %v", err)
	}
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:        "node-" + providerKey,
		AccountID: accountID,
		PublicKey: providerKey,
	}); err != nil {
		t.Fatalf("upsert provider (ownership): %v", err)
	}
}

// TestNodeEarningsRequiresAuth is the regression: the endpoint must
// reject an unauthenticated caller (no Privy user in context) with 401, because
// provider_key is not secret.
func TestNodeEarningsRequiresAuth(t *testing.T) {
	srv, st := testWithdrawServer(t)
	seedNodeEarning(t, st, "acct-A", "key-A", "job-1", 300_000)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=key-A", nil)
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401: %s", w.Code, w.Body.String())
	}
}

// TestNodeEarningsRejectsCrossAccount verifies a Privy user cannot read another
// account's node earnings (the actual cross-account leak this fixes).
func TestNodeEarningsRejectsCrossAccount(t *testing.T) {
	srv, st := testWithdrawServer(t)
	seedNodeEarning(t, st, "acct-A", "key-A", "job-1", 777_000)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=key-A", nil)
	req = withPrivyUser(req, &store.User{AccountID: "acct-B"})
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403: %s", w.Code, w.Body.String())
	}
	if body := w.Body.String(); strings.Contains(body, "777000") || strings.Contains(body, "0.777") {
		t.Fatalf("forbidden response leaked owner totals: %s", body)
	}
}

// TestNodeEarningsAllowsOwner verifies the owning account gets a 200 with the
// node's lifetime totals.
func TestNodeEarningsAllowsOwner(t *testing.T) {
	srv, st := testWithdrawServer(t)
	seedNodeEarning(t, st, "acct-A", "key-A", "job-1", 300_000)
	seedNodeEarning(t, st, "acct-A", "key-A", "job-2", 200_000)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=key-A", nil)
	req = withPrivyUser(req, &store.User{AccountID: "acct-A"})
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", w.Code, w.Body.String())
	}
	var resp nodeEarningsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.TotalMicroUSD != 500_000 {
		t.Fatalf("total_micro_usd = %d, want 500000", resp.TotalMicroUSD)
	}
}

// TestNodeEarningsOwnerWithNoEarningsGets200 is the review regression:
// ownership now resolves from the persisted record (not by sampling an earnings
// row), so a legitimately-owned machine that hasn't earned yet returns 200 with
// empty totals instead of a false 403. The old earnings-row check 403'd here.
func TestNodeEarningsOwnerWithNoEarningsGets200(t *testing.T) {
	srv, st := testWithdrawServer(t)
	// Owned machine, zero earnings: persist the record but record no earning.
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID: "node-key-new", AccountID: "acct-A", PublicKey: "key-new",
	}); err != nil {
		t.Fatalf("upsert provider: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=key-new", nil)
	req = withPrivyUser(req, &store.User{AccountID: "acct-A"})
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (owner with no earnings): %s", w.Code, w.Body.String())
	}
	var resp nodeEarningsResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if resp.TotalMicroUSD != 0 || resp.Count != 0 || len(resp.Earnings) != 0 {
		t.Fatalf("want empty totals, got total=%d count=%d earnings=%d", resp.TotalMicroUSD, resp.Count, len(resp.Earnings))
	}
}

// TestNodeEarningsUnknownKeyForbidden verifies an authenticated caller asking
// for a key with no earnings gets 403 (not 404), so node existence isn't leaked.
func TestNodeEarningsUnknownKeyForbidden(t *testing.T) {
	srv, _ := testWithdrawServer(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/provider/node-earnings?provider_key=does-not-exist", nil)
	req = withPrivyUser(req, &store.User{AccountID: "acct-A"})
	w := httptest.NewRecorder()
	srv.handleNodeEarnings(w, req)

	if w.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403: %s", w.Code, w.Body.String())
	}
}

// TestAttachEarningsIsPerNodeNotAccountTotal is the regression for the
// fleet dashboard: each machine's earnings must reflect its own provider_key,
// not the account total stamped on every card. Fails on the pre-fix code where
// both machines would show the account total of 1_000_000.
func TestAttachEarningsIsPerNodeNotAccountTotal(t *testing.T) {
	srv, st := testWithdrawServer(t)

	const acct = "acct-multi"
	seedNodeEarning(t, st, acct, "k1", "j1", 300_000)
	seedNodeEarning(t, st, acct, "k2", "j2a", 400_000)
	seedNodeEarning(t, st, acct, "k2", "j2b", 300_000)

	mp1 := &myProvider{AccountID: acct, ProviderKey: "k1"}
	mp2 := &myProvider{AccountID: acct, ProviderKey: "k2"}
	srv.attachEarnings(mp1)
	srv.attachEarnings(mp2)

	if mp1.EarningsTotalMicroUSD != 300_000 || mp1.EarningsCount != 1 {
		t.Fatalf("k1 earnings = %d/%d, want 300000/1", mp1.EarningsTotalMicroUSD, mp1.EarningsCount)
	}
	if mp2.EarningsTotalMicroUSD != 700_000 || mp2.EarningsCount != 2 {
		t.Fatalf("k2 earnings = %d/%d, want 700000/2", mp2.EarningsTotalMicroUSD, mp2.EarningsCount)
	}
	const accountTotal = 1_000_000
	if mp1.EarningsTotalMicroUSD == accountTotal || mp2.EarningsTotalMicroUSD == accountTotal {
		t.Fatalf("a machine showed the account total %d instead of per-node earnings", accountTotal)
	}
}

// TestAttachEarningsOfflineMachineHasNoKeyShowsZero documents the offline
// limitation: a machine with no resolvable X25519 key reports $0 rather than
// falling back to the account total (which would reintroduce the bug).
func TestAttachEarningsOfflineMachineHasNoKeyShowsZero(t *testing.T) {
	srv, st := testWithdrawServer(t)

	const acct = "acct-offline"
	seedNodeEarning(t, st, acct, "some-other-key", "j1", 500_000)

	mp := &myProvider{AccountID: acct, ProviderKey: ""}
	srv.attachEarnings(mp)

	if mp.EarningsTotalMicroUSD != 0 || mp.EarningsCount != 0 {
		t.Fatalf("offline machine earnings = %d/%d, want 0/0", mp.EarningsTotalMicroUSD, mp.EarningsCount)
	}
}

// TestBuildMyProviderOfflineResolvesEarningsFromPersistedKey is the
// review fix: persisting the X25519 key on the record lets an OFFLINE machine
// (no live provider) still resolve its real per-box earnings, instead of
// reporting $0. buildMyProvider must copy rec.PublicKey into ProviderKey so the
// subsequent attachEarnings finds the node's rows.
func TestBuildMyProviderOfflineResolvesEarningsFromPersistedKey(t *testing.T) {
	srv, st := testWithdrawServer(t)

	const acct = "acct-off2"
	seedNodeEarning(t, st, acct, "persisted-key", "j1", 250_000)

	// Offline machine: build from the persisted record only (no live provider).
	mp := buildMyProvider(&store.ProviderRecord{
		ID: "node-persisted-key", AccountID: acct, PublicKey: "persisted-key",
	}, nil)
	if mp.ProviderKey != "persisted-key" {
		t.Fatalf("ProviderKey = %q, want persisted-key (record key must populate offline)", mp.ProviderKey)
	}
	srv.attachEarnings(&mp)
	if mp.EarningsTotalMicroUSD != 250_000 || mp.EarningsCount != 1 {
		t.Fatalf("offline-with-key earnings = %d/%d, want 250000/1", mp.EarningsTotalMicroUSD, mp.EarningsCount)
	}
}
