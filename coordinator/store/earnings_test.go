package store

import (
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

func TestProviderEarnings_GetByProviderKey(t *testing.T) {
	s := NewMemory(Config{})

	// Record earnings for two different nodes.
	for i := range 5 {
		key := "key-A"
		if i%2 == 0 {
			key = "key-B"
		}
		_ = s.RecordProviderEarning(&ProviderEarning{
			AccountID: "acct-1", ProviderID: "prov-X", ProviderKey: key,
			JobID: "job-" + string(rune('a'+i)), Model: "test-model",
			AmountMicroUSD: int64(1000 * (i + 1)),
			PromptTokens:   10, CompletionTokens: 50,
		})
	}

	// key-A should have 2 earnings (i=1, i=3)
	earningsA, err := s.GetProviderEarnings("key-A", 50)
	if err != nil {
		t.Fatalf("GetProviderEarnings key-A: %v", err)
	}
	if len(earningsA) != 2 {
		t.Errorf("expected 2 earnings for key-A, got %d", len(earningsA))
	}

	// key-B should have 3 earnings (i=0, i=2, i=4)
	earningsB, err := s.GetProviderEarnings("key-B", 50)
	if err != nil {
		t.Fatalf("GetProviderEarnings key-B: %v", err)
	}
	if len(earningsB) != 3 {
		t.Errorf("expected 3 earnings for key-B, got %d", len(earningsB))
	}

	// Nonexistent key should return empty slice.
	earningsC, err := s.GetProviderEarnings("key-C", 50)
	if err != nil {
		t.Fatalf("GetProviderEarnings key-C: %v", err)
	}
	if len(earningsC) != 0 {
		t.Errorf("expected 0 earnings for key-C, got %d", len(earningsC))
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

	earnings, _ := s.GetProviderEarnings("key-1", 50)
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
	earnings, err := s.GetProviderEarnings("key-1", 3)
	if err != nil {
		t.Fatalf("GetProviderEarnings: %v", err)
	}
	if len(earnings) != 3 {
		t.Errorf("expected 3 earnings with limit=3, got %d", len(earnings))
	}
	// Should be the 3 newest (IDs 10, 9, 8).
	if earnings[0].ID != 10 {
		t.Errorf("first earning ID = %d, want 10", earnings[0].ID)
	}

	// Limit also works for account earnings.
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
