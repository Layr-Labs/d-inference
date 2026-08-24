package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	apitypes "github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type accountSummaryErrorStore struct {
	store.Store
	err error
}

func (s *accountSummaryErrorStore) GetAccountEarningsSummary(string) (store.ProviderEarningsSummary, error) {
	return store.ProviderEarningsSummary{}, s.err
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

func TestAccountEarningsHTTPSummaryReadSemantics(t *testing.T) {
	request := func(t *testing.T, srv *Server, st store.Store, rawToken, accountID string) *httptest.ResponseRecorder {
		t.Helper()
		tokenHash := sha256.Sum256([]byte(rawToken))
		if err := st.CreateProviderToken(&store.ProviderToken{
			TokenHash: fmt.Sprintf("%x", tokenHash[:]),
			AccountID: accountID,
			Active:    true,
		}); err != nil {
			t.Fatalf("create provider token: %v", err)
		}
		req := httptest.NewRequest(http.MethodGet, "/v1/provider/account-earnings", nil)
		req.Header.Set("Authorization", "Bearer "+rawToken)
		rec := httptest.NewRecorder()
		srv.Handler().ServeHTTP(rec, req)
		return rec
	}

	t.Run("empty account is zero summary", func(t *testing.T) {
		srv, st := testWithdrawServer(t)
		rec := request(t, srv, st, "eigeninference-pt-empty-summary", "acct-empty-summary")
		if rec.Code != http.StatusOK {
			t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
		}
		var response apitypes.AccountEarningsResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
			t.Fatal(err)
		}
		if response.Count != 0 || response.TotalMicroUSD != 0 {
			t.Fatalf("empty summary = %+v, want zero count and total", response)
		}
	})

	t.Run("operational error fails closed", func(t *testing.T) {
		srv, st := testWithdrawServer(t)
		operationalErr := errors.New("summary database unavailable")
		srv.store = &accountSummaryErrorStore{Store: st, err: operationalErr}

		rec := request(t, srv, st, "eigeninference-pt-failed-summary", "acct-failed-summary")
		if rec.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500: %s", rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), "failed to fetch earnings summary") {
			t.Fatalf("unexpected error response: %s", rec.Body.String())
		}
	})
}

func TestAccountEarningsReflectsWritesImmediately(t *testing.T) {
	srv, st := testWithdrawServer(t)
	const accountID = "acct-immediate-earnings"

	credit := func(jobID string, amount int64) {
		t.Helper()
		if err := st.CreditProviderAccount(&store.ProviderEarning{
			AccountID:      accountID,
			ProviderKey:    "key-immediate",
			JobID:          jobID,
			Model:          "qwen3.5-9b",
			AmountMicroUSD: amount,
			CreatedAt:      time.Now(),
		}); err != nil {
			t.Fatalf("credit %s: %v", jobID, err)
		}
	}
	read := func() apitypes.AccountEarningsResponse {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/v1/provider/account-earnings", nil)
		req = req.WithContext(context.WithValue(req.Context(), ctxKeyConsumer, accountID))
		w := httptest.NewRecorder()
		srv.handleAccountEarnings(w, req)
		if w.Code != http.StatusOK {
			t.Fatalf("status = %d: %s", w.Code, w.Body.String())
		}
		var response apitypes.AccountEarningsResponse
		if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
			t.Fatalf("decode response: %v", err)
		}
		return response
	}

	credit("job-first", 100_000)
	first := read()
	if first.Count != 1 || first.AvailableBalanceMicroUSD != 100_000 {
		t.Fatalf("first response = %+v", first)
	}

	credit("job-second", 200_000)
	second := read()
	if second.Count != 2 || second.AvailableBalanceMicroUSD != 300_000 {
		t.Fatalf("second response remained stale: %+v", second)
	}
}

func TestAccountEarningsProviderTokenReturnsCompleteLinkedHistory(t *testing.T) {
	srv, st := testWithdrawServer(t)
	const (
		accountID         = "acct-linked-history"
		rawToken          = "eigeninference-pt-linked-history"
		serialNumber      = "SERIAL-HISTORY-1"
		currentSessionID  = "provider-session-current"
		currentKey        = "provider-key-current"
		previousSessionID = "provider-session-previous"
		previousKey       = "provider-key-previous"
	)

	tokenHash := sha256.Sum256([]byte(rawToken))
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: fmt.Sprintf("%x", tokenHash[:]),
		AccountID: accountID,
		Active:    true,
	}); err != nil {
		t.Fatalf("create provider token: %v", err)
	}
	for _, session := range []struct {
		id  string
		key string
	}{
		{previousSessionID, previousKey},
		{currentSessionID, currentKey},
	} {
		if err := st.OpenProviderSession(
			context.Background(),
			session.id,
			serialNumber,
			accountID,
		); err != nil {
			t.Fatalf("open provider session %s: %v", session.id, err)
		}
		if err := st.TouchProviderSession(
			context.Background(),
			session.id,
			serialNumber,
			accountID,
			session.key,
			time.Now(),
		); err != nil {
			t.Fatalf("touch provider session %s: %v", session.id, err)
		}
	}
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:           currentSessionID,
		AccountID:    accountID,
		PublicKey:    currentKey,
		SerialNumber: serialNumber,
		LastSeen:     time.Now(),
	}); err != nil {
		t.Fatalf("upsert provider: %v", err)
	}
	if err := st.CreditProviderAccount(&store.ProviderEarning{
		AccountID:        accountID,
		ProviderID:       previousSessionID,
		ProviderKey:      previousKey,
		JobID:            "job-previous-session",
		Model:            "qwen3.5-9b",
		AmountMicroUSD:   100_000,
		PromptTokens:     40,
		CompletionTokens: 10,
		CreatedAt:        time.Now().Add(-2 * time.Minute),
	}); err != nil {
		t.Fatalf("credit previous provider session: %v", err)
	}
	if err := st.CreditProviderAccount(&store.ProviderEarning{
		AccountID:        accountID,
		ProviderID:       currentSessionID,
		ProviderKey:      currentKey,
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
		ProviderKey:    currentKey,
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

	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if strings.Contains(string(body), serialNumber) {
		t.Fatalf("earnings response exposed hardware serial: %s", body)
	}
	var payload apitypes.AccountEarningsResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload.AccountID != accountID {
		t.Fatalf("account_id = %q, want %q", payload.AccountID, accountID)
	}
	if payload.TotalMicroUSD != 850_000 || payload.Count != 2 {
		t.Fatalf("summary = (%d, %d), want (850000, 2)", payload.TotalMicroUSD, payload.Count)
	}
	if len(payload.Earnings) != 3 {
		t.Fatalf("earnings length = %d, want 3", len(payload.Earnings))
	}
	var inference, floor *store.ProviderEarning
	for i := range payload.Earnings {
		switch payload.Earnings[i].JobID {
		case "job-linked":
			inference = &payload.Earnings[i]
		case "floor:2026-08:" + currentKey:
			floor = &payload.Earnings[i]
		}
	}
	if inference == nil || inference.PromptTokens != 120 || inference.CompletionTokens != 45 {
		t.Fatalf("inference earning missing token detail: %+v", inference)
	}
	if floor == nil || floor.AmountMicroUSD != 450_000 {
		t.Fatalf("base reward missing from history: %+v", floor)
	}
	if len(payload.Providers) != 2 {
		t.Fatalf("providers length = %d, want 2", len(payload.Providers))
	}
	expectedMachineID := providerMachineID(serialNumber)
	identityByKey := make(map[string]apitypes.AccountEarningsProvider, len(payload.Providers))
	for _, identity := range payload.Providers {
		identityByKey[identity.ProviderKey] = identity
	}
	for key, sessionID := range map[string]string{
		previousKey: previousSessionID,
		currentKey:  currentSessionID,
	} {
		identity, ok := identityByKey[key]
		if !ok {
			t.Fatalf("missing provider identity for %q: %+v", key, payload.Providers)
		}
		if identity.ProviderID != sessionID || identity.MachineID != expectedMachineID {
			t.Fatalf("provider identity for %q = %+v", key, identity)
		}
	}
}
