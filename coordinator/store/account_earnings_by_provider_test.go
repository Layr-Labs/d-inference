package store

import (
	"testing"
	"time"
)

// TestGetAccountEarningsByProvider verifies grouping is keyed on the stable
// provider_key (not the rotating provider_id), sorted by total descending,
// with base_reward rows counted in money but not in jobs/tokens.
func TestGetAccountEarningsByProvider(t *testing.T) {
	s := NewMemory(Config{})
	now := time.Now()

	entries := []ProviderEarning{
		// machine A earns across two connections (rotating provider_id).
		{AccountID: "acct", ProviderID: "conn-1", ProviderKey: "key-a", JobID: "j1",
			Model: "qwen3.5-35b-a3b", AmountMicroUSD: 100_000, PromptTokens: 10, CompletionTokens: 5,
			CreatedAt: now.Add(-3 * time.Hour)},
		{AccountID: "acct", ProviderID: "conn-2", ProviderKey: "key-a", JobID: "j2",
			Model: "qwen3.5-35b-a3b", AmountMicroUSD: 100_000, PromptTokens: 10, CompletionTokens: 5,
			CreatedAt: now.Add(-1 * time.Hour)},
		{AccountID: "acct", ProviderID: "conn-3", ProviderKey: "key-a", JobID: "j3",
			Model: "base_reward", AmountMicroUSD: 50_000, CreatedAt: now.Add(-2 * time.Hour)},
		// machine B.
		{AccountID: "acct", ProviderID: "conn-4", ProviderKey: "key-b", JobID: "j4",
			Model: "qwen3.5-35b-a3b", AmountMicroUSD: 400_000, PromptTokens: 40, CompletionTokens: 20,
			CreatedAt: now.Add(-30 * time.Minute)},
		// Another account must not leak in.
		{AccountID: "other", ProviderID: "conn-5", ProviderKey: "key-a", JobID: "j5",
			Model: "qwen3.5-35b-a3b", AmountMicroUSD: 999_000, CreatedAt: now},
	}
	for _, e := range entries {
		if err := s.CreditProviderAccount(&e); err != nil {
			t.Fatalf("credit: %v", err)
		}
	}

	got, err := s.GetAccountEarningsByProvider("acct")
	if err != nil {
		t.Fatalf("GetAccountEarningsByProvider: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("groups = %d, want 2", len(got))
	}

	// Sorted by total descending: key-b (400k) before key-a (250k).
	if got[0].ProviderKey != "key-b" || got[0].TotalMicroUSD != 400_000 {
		t.Fatalf("first = %q/%d, want key-b/400000", got[0].ProviderKey, got[0].TotalMicroUSD)
	}
	a := got[1]
	if a.ProviderKey != "key-a" {
		t.Fatalf("second = %q, want key-a", a.ProviderKey)
	}
	if a.TotalMicroUSD != 250_000 {
		t.Fatalf("key-a total = %d, want 250000 (includes base reward)", a.TotalMicroUSD)
	}
	if a.JobCount != 2 {
		t.Fatalf("key-a job_count = %d, want 2 (base_reward excluded)", a.JobCount)
	}
	if a.PromptTokens != 20 || a.CompletionTokens != 10 {
		t.Fatalf("key-a tokens = %d/%d, want 20/10", a.PromptTokens, a.CompletionTokens)
	}
	if !a.LastEarnedAt.Equal(now.Add(-1 * time.Hour)) {
		t.Fatalf("key-a last_earned_at = %v, want %v", a.LastEarnedAt, now.Add(-1*time.Hour))
	}

	// Empty account → empty slice, not nil error.
	empty, err := s.GetAccountEarningsByProvider("nobody")
	if err != nil || len(empty) != 0 {
		t.Fatalf("empty account: got %v, %v", empty, err)
	}
}
