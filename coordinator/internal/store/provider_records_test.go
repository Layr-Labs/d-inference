package store

import (
	"context"
	"testing"
	"time"
)

func TestListProvidersByAccount_FiltersByAccount(t *testing.T) {
	st := NewMemory("")
	ctx := context.Background()

	now := time.Now()
	records := []ProviderRecord{
		{ID: "alice-1", AccountID: "acct-alice", LastSeen: now.Add(-2 * time.Hour)},
		{ID: "alice-2", AccountID: "acct-alice", LastSeen: now.Add(-1 * time.Hour)},
		{ID: "bob-1", AccountID: "acct-bob", LastSeen: now},
		{ID: "anon-1", AccountID: "", LastSeen: now},
	}
	for _, r := range records {
		if err := st.UpsertProvider(ctx, r); err != nil {
			t.Fatalf("upsert: %v", err)
		}
	}

	got, err := st.ListProvidersByAccount(ctx, "acct-alice")
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	// Should be ordered by LastSeen DESC.
	if got[0].ID != "alice-2" || got[1].ID != "alice-1" {
		t.Fatalf("ordering wrong, got %v", []string{got[0].ID, got[1].ID})
	}
	for _, r := range got {
		if r.AccountID != "acct-alice" {
			t.Fatalf("leaked record from %q", r.AccountID)
		}
	}
}

func TestListProvidersByAccount_EmptyAccount(t *testing.T) {
	st := NewMemory("")
	ctx := context.Background()

	if err := st.UpsertProvider(ctx, ProviderRecord{ID: "p1", AccountID: ""}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	got, err := st.ListProvidersByAccount(ctx, "")
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got == nil {
		t.Fatal("got nil, want empty slice")
	}
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}

func TestListProvidersByAccount_UnknownAccount(t *testing.T) {
	st := NewMemory("")
	ctx := context.Background()

	if err := st.UpsertProvider(ctx, ProviderRecord{ID: "p1", AccountID: "acct-real"}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	got, err := st.ListProvidersByAccount(ctx, "acct-ghost")
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if got == nil || len(got) != 0 {
		t.Fatalf("got %v, want empty slice", got)
	}
}

func TestListProvidersByAccount_AccountReassignment(t *testing.T) {
	st := NewMemory("")
	ctx := context.Background()

	// Provider initially linked to alice, then re-linked to bob.
	if err := st.UpsertProvider(ctx, ProviderRecord{ID: "p1", AccountID: "acct-alice", LastSeen: time.Now()}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if err := st.UpsertProvider(ctx, ProviderRecord{ID: "p1", AccountID: "acct-bob", LastSeen: time.Now()}); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	aliceRecs, _ := st.ListProvidersByAccount(ctx, "acct-alice")
	if len(aliceRecs) != 0 {
		t.Fatalf("alice still has %d providers after reassignment", len(aliceRecs))
	}
	bobRecs, _ := st.ListProvidersByAccount(ctx, "acct-bob")
	if len(bobRecs) != 1 || bobRecs[0].ID != "p1" {
		t.Fatalf("bob should own p1, got %v", bobRecs)
	}
}

// TestPostgresListProvidersByAccount mirrors the memory-store contract on the
// real database. Skips when DATABASE_URL is unset (dev / CI without postgres).
func TestPostgresListProvidersByAccount(t *testing.T) {
	st := testPostgresStore(t)
	ctx := context.Background()

	now := time.Now()
	for _, rec := range []ProviderRecord{
		{ID: "alice-old", AccountID: "acct-alice", SerialNumber: "AAA1", LastSeen: now.Add(-2 * time.Hour)},
		{ID: "alice-new", AccountID: "acct-alice", SerialNumber: "AAA2", LastSeen: now.Add(-1 * time.Hour)},
		{ID: "bob-1", AccountID: "acct-bob", SerialNumber: "BBB1", LastSeen: now},
		{ID: "anon-1", AccountID: "", SerialNumber: "CCC1", LastSeen: now},
	} {
		if err := st.UpsertProvider(ctx, rec); err != nil {
			t.Fatalf("upsert %s: %v", rec.ID, err)
		}
	}

	got, err := st.ListProvidersByAccount(ctx, "acct-alice")
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	// Postgres returns ORDER BY last_seen DESC.
	if got[0].ID != "alice-new" || got[1].ID != "alice-old" {
		t.Fatalf("ordering wrong, got %v", []string{got[0].ID, got[1].ID})
	}

	bobRecs, err := st.ListProvidersByAccount(ctx, "acct-bob")
	if err != nil {
		t.Fatalf("list bob: %v", err)
	}
	if len(bobRecs) != 1 || bobRecs[0].ID != "bob-1" {
		t.Fatalf("bob should own only bob-1, got %v", bobRecs)
	}

	emptyRecs, err := st.ListProvidersByAccount(ctx, "")
	if err != nil {
		t.Fatalf("list empty: %v", err)
	}
	if len(emptyRecs) != 0 {
		t.Fatalf("empty accountID should not match unlinked rows, got %d", len(emptyRecs))
	}

	ghostRecs, err := st.ListProvidersByAccount(ctx, "acct-ghost")
	if err != nil {
		t.Fatalf("list ghost: %v", err)
	}
	if len(ghostRecs) != 0 {
		t.Fatalf("unknown account should return empty, got %d", len(ghostRecs))
	}
}
