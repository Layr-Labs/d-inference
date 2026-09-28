package store

import (
	"context"
	"testing"
	"time"
)

func TestProviderEarnings_RecordAndGetByAccount(t *testing.T) {
	s := NewMemory(Config{})

	// Record three earnings for the same account, two different nodes.
	e1 := &ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-A", ProviderKey: "key-A",
		JobID: "job-1", Model: "qwen3.5-9b", AmountMicroUSD: 1000,
		PromptTokens: 10, CompletionTokens: 50,
		CreatedAt: time.Now().Add(-2 * time.Minute),
	}
	e2 := &ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-B", ProviderKey: "key-B",
		JobID: "job-2", Model: "llama-3", AmountMicroUSD: 2000,
		PromptTokens: 20, CompletionTokens: 100,
		CreatedAt: time.Now().Add(-1 * time.Minute),
	}
	e3 := &ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-A", ProviderKey: "key-A",
		JobID: "job-3", Model: "qwen3.5-9b", AmountMicroUSD: 1500,
		PromptTokens: 15, CompletionTokens: 75,
		CreatedAt: time.Now(),
	}

	for _, e := range []*ProviderEarning{e1, e2, e3} {
		if err := s.RecordProviderEarning(e); err != nil {
			t.Fatalf("RecordProviderEarning: %v", err)
		}
	}

	// GetAccountEarnings should return all three, newest first.
	earnings, err := s.GetAccountEarnings("acct-1", 50)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(earnings) != 3 {
		t.Fatalf("expected 3 earnings, got %d", len(earnings))
	}
	// Newest first: e3 has ID 3, e2 has ID 2, e1 has ID 1
	if earnings[0].JobID != "job-3" {
		t.Errorf("first earning should be job-3, got %q", earnings[0].JobID)
	}
	if earnings[1].JobID != "job-2" {
		t.Errorf("second earning should be job-2, got %q", earnings[1].JobID)
	}
	if earnings[2].JobID != "job-1" {
		t.Errorf("third earning should be job-1, got %q", earnings[2].JobID)
	}

	// IDs should be auto-assigned.
	if earnings[0].ID != 3 || earnings[1].ID != 2 || earnings[2].ID != 1 {
		t.Errorf("IDs should be auto-assigned: got %d, %d, %d", earnings[0].ID, earnings[1].ID, earnings[2].ID)
	}
}

func TestProviderEarnings_NewestFirst(t *testing.T) {
	s := NewMemory(Config{})

	// Record in chronological order.
	for i := range 5 {
		_ = s.RecordProviderEarning(&ProviderEarning{
			AccountID: "acct-1", ProviderID: "prov-1", ProviderKey: "key-1",
			JobID: string(rune('a' + i)), Model: "test-model",
			AmountMicroUSD: int64(i + 1),
		})
	}

	earnings, _ := s.GetAccountEarnings("acct-1", 50)
	if len(earnings) != 5 {
		t.Fatalf("expected 5 earnings, got %d", len(earnings))
	}
	// Newest first means highest ID first.
	for i := range len(earnings) - 1 {
		if earnings[i].ID < earnings[i+1].ID {
			t.Errorf("earnings not in newest-first order: ID %d before ID %d", earnings[i].ID, earnings[i+1].ID)
		}
	}
}

func TestProviderEarnings_LimitRespected(t *testing.T) {
	s := NewMemory(Config{})

	// Record 10 earnings.
	for i := range 10 {
		_ = s.RecordProviderEarning(&ProviderEarning{
			AccountID: "acct-1", ProviderID: "prov-1", ProviderKey: "key-1",
			JobID: string(rune('a' + i)), Model: "test-model",
			AmountMicroUSD: int64(i + 1),
		})
	}

	// Limit to 3.
	earnings, err := s.GetAccountEarnings("acct-1", 3)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(earnings) != 3 {
		t.Errorf("expected 3 earnings with limit=3, got %d", len(earnings))
	}
	// Should be the 3 newest (IDs 10, 9, 8).
	if earnings[0].ID != 10 {
		t.Errorf("first earning ID = %d, want 10", earnings[0].ID)
	}

	// A second limit returns that many.
	acctEarnings, err := s.GetAccountEarnings("acct-1", 5)
	if err != nil {
		t.Fatalf("GetAccountEarnings: %v", err)
	}
	if len(acctEarnings) != 5 {
		t.Errorf("expected 5 account earnings with limit=5, got %d", len(acctEarnings))
	}
}

func TestProviderEarnings_DifferentAccounts(t *testing.T) {
	s := NewMemory(Config{})

	// Record earnings for two different accounts.
	_ = s.RecordProviderEarning(&ProviderEarning{
		AccountID: "acct-1", ProviderID: "prov-1", ProviderKey: "key-1",
		JobID: "job-1", Model: "test-model", AmountMicroUSD: 1000,
	})
	_ = s.RecordProviderEarning(&ProviderEarning{
		AccountID: "acct-2", ProviderID: "prov-2", ProviderKey: "key-2",
		JobID: "job-2", Model: "test-model", AmountMicroUSD: 2000,
	})

	// acct-1 should only see 1 earning.
	e1, _ := s.GetAccountEarnings("acct-1", 50)
	if len(e1) != 1 {
		t.Errorf("expected 1 earning for acct-1, got %d", len(e1))
	}
	if e1[0].AmountMicroUSD != 1000 {
		t.Errorf("expected amount 1000, got %d", e1[0].AmountMicroUSD)
	}

	// acct-2 should only see 1 earning.
	e2, _ := s.GetAccountEarnings("acct-2", 50)
	if len(e2) != 1 {
		t.Errorf("expected 1 earning for acct-2, got %d", len(e2))
	}
	if e2[0].AmountMicroUSD != 2000 {
		t.Errorf("expected amount 2000, got %d", e2[0].AmountMicroUSD)
	}
}

// TestRecordProviderEarningMaintainsSummaryWithoutRestart: a retried
// earning (same job_id) updates the account summary exactly once, live, and
// never touches balances.
func TestRecordProviderEarningMaintainsSummaryWithoutRestart(t *testing.T) {
	s := testPostgresStore(t)
	e := &ProviderEarning{AccountID: uniqueID("account"), ProviderKey: uniqueID("key"), ProviderID: "p", JobID: uniqueID("job"), Model: "m", AmountMicroUSD: 100, PromptTokens: 20, CompletionTokens: 30}
	for i := 0; i < 2; i++ {
		if err := s.RecordProviderEarning(e); err != nil {
			t.Fatal(err)
		}
	}
	var count, money, prompt, completion int64
	if err := s.pool.QueryRow(context.Background(), `SELECT total_count,total_micro_usd,total_prompt_tokens,total_completion_tokens FROM earnings_summary WHERE key=$1 AND key_type='account'`, e.AccountID).Scan(&count, &money, &prompt, &completion); err != nil {
		t.Fatal(err)
	}
	if count != 1 || money != 100 || prompt != 20 || completion != 30 {
		t.Fatalf("summary doubled/lost: %d %d %d %d", count, money, prompt, completion)
	}
	var balanceRows int
	if err := s.pool.QueryRow(context.Background(), `SELECT count(*) FROM balances WHERE account_id=$1`, e.AccountID).Scan(&balanceRows); err != nil || balanceRows != 0 {
		t.Fatalf("record-only unexpectedly credited balance: %d %v", balanceRows, err)
	}
}

// TestBaseRewardEarningPathsExcludeInferenceWork: base-reward earnings add
// money to the account summary but never inference work (count or tokens),
// on both the record-only and the credit path, in both store backends.
func TestBaseRewardEarningPathsExcludeInferenceWork(t *testing.T) {
	for name, st := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			for _, credit := range []bool{false, true} {
				acct := uniqueID("base-acct")
				key := uniqueID("base-key")
				e := &ProviderEarning{AccountID: acct, ProviderKey: key, ProviderID: "p", JobID: uniqueID("base-job"), Model: "base_reward", AmountMicroUSD: 800, PromptTokens: 999, CompletionTokens: 999}
				for i := 0; i < 2; i++ {
					var err error
					if credit {
						err = st.CreditProviderAccount(e)
					} else {
						err = st.RecordProviderEarning(e)
					}
					if err != nil {
						t.Fatal(err)
					}
				}
				accountSummary, err := st.GetAccountEarningsSummary(acct)
				if err != nil {
					t.Fatal(err)
				}
				if accountSummary.Count != 0 || accountSummary.TotalMicroUSD != 800 || accountSummary.PromptTokens != 0 || accountSummary.CompletionTokens != 0 {
					t.Fatalf("base reward counted as work: %+v", accountSummary)
				}
			}
		})
	}
}
