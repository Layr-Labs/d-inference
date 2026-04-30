package store

import (
	"context"
	"testing"
	"time"
)

func TestMemoryListProvidersByAccount(t *testing.T) {
	st := NewMemory("")
	ctx := context.Background()
	now := time.Now()

	records := []ProviderRecord{
		{ID: "p-old", AccountID: "acct-1", LastSeen: now.Add(-time.Hour)},
		{ID: "p-other", AccountID: "acct-2", LastSeen: now},
		{ID: "p-new", AccountID: "acct-1", LastSeen: now},
	}
	for _, rec := range records {
		if err := st.UpsertProvider(ctx, rec); err != nil {
			t.Fatalf("UpsertProvider(%s): %v", rec.ID, err)
		}
	}

	got, err := st.ListProvidersByAccount(ctx, "acct-1")
	if err != nil {
		t.Fatalf("ListProvidersByAccount: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	if got[0].ID != "p-new" || got[1].ID != "p-old" {
		t.Fatalf("records ordered by last_seen desc = [%s %s], want [p-new p-old]", got[0].ID, got[1].ID)
	}

	empty, err := st.ListProvidersByAccount(ctx, "")
	if err != nil {
		t.Fatalf("empty ListProvidersByAccount: %v", err)
	}
	if len(empty) != 0 {
		t.Fatalf("empty account returned %d records, want 0", len(empty))
	}
}
