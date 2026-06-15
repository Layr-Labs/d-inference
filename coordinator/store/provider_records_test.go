package store

import (
	"context"
	"testing"
	"time"
)

func TestMemoryListProvidersByAccount(t *testing.T) {
	st := NewMemory(Config{})
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

// TestMemoryDeleteProvidersBySerial verifies the hard delete: all rows
// sharing a serial for the owner are removed (plus their reputation), other
// accounts are untouched, and the serial index is cleaned up.
func TestMemoryDeleteProvidersBySerial(t *testing.T) {
	st := NewMemory(Config{})
	ctx := context.Background()
	now := time.Now()

	// Two session rows for acct-1 sharing serial SER, one for acct-2.
	for _, rec := range []ProviderRecord{
		{ID: "a", SerialNumber: "SER", AccountID: "acct-1", LastSeen: now},
		{ID: "b", SerialNumber: "SER", AccountID: "acct-1", LastSeen: now},
		{ID: "c", SerialNumber: "SER2", AccountID: "acct-2", LastSeen: now},
	} {
		if err := st.UpsertProvider(ctx, rec); err != nil {
			t.Fatalf("UpsertProvider(%s): %v", rec.ID, err)
		}
	}
	// Seed a reputation row that must be removed alongside the provider.
	if err := st.UpsertReputation(ctx, "a", ReputationRecord{TotalJobs: 5}); err != nil {
		t.Fatalf("UpsertReputation: %v", err)
	}

	n, err := st.DeleteProvidersBySerial(ctx, "acct-1", "SER")
	if err != nil {
		t.Fatalf("DeleteProvidersBySerial: %v", err)
	}
	if n != 2 {
		t.Fatalf("rows_removed = %d, want 2", n)
	}

	if got, _ := st.ListProvidersByAccount(ctx, "acct-1"); len(got) != 0 {
		t.Fatalf("acct-1 still has %d records", len(got))
	}
	if got, _ := st.ListProvidersByAccount(ctx, "acct-2"); len(got) != 1 {
		t.Fatalf("acct-2 records = %d, want 1 (must be untouched)", len(got))
	}
	if rep, _ := st.GetReputation(ctx, "a"); rep != nil {
		t.Fatal("reputation row for deleted provider still present")
	}
	// Serial index for SER must be gone; a fresh insert under SER must succeed.
	if rec, _ := st.GetProviderBySerial(ctx, "SER"); rec != nil {
		t.Fatal("serial index for SER not cleaned up")
	}
}

// TestMemoryDeleteProvidersBySerial_ByID verifies deletion of an empty-serial
// record by its session id.
func TestMemoryDeleteProvidersBySerial_ByID(t *testing.T) {
	st := NewMemory(Config{})
	ctx := context.Background()

	if err := st.UpsertProvider(ctx, ProviderRecord{ID: "noserial", AccountID: "acct-1", LastSeen: time.Now()}); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}

	n, err := st.DeleteProvidersBySerial(ctx, "acct-1", "noserial")
	if err != nil {
		t.Fatalf("DeleteProvidersBySerial: %v", err)
	}
	if n != 1 {
		t.Fatalf("rows_removed = %d, want 1", n)
	}
	if rec, _ := st.GetProviderRecord(ctx, "noserial"); rec != nil {
		t.Fatal("record still present after delete by id")
	}
}

// TestMemoryDeleteProvidersBySerial_WrongOwnerNoOp verifies a non-owner delete
// removes nothing.
func TestMemoryDeleteProvidersBySerial_WrongOwnerNoOp(t *testing.T) {
	st := NewMemory(Config{})
	ctx := context.Background()

	if err := st.UpsertProvider(ctx, ProviderRecord{ID: "a", SerialNumber: "SER", AccountID: "acct-1", LastSeen: time.Now()}); err != nil {
		t.Fatalf("UpsertProvider: %v", err)
	}

	n, err := st.DeleteProvidersBySerial(ctx, "acct-2", "SER")
	if err != nil {
		t.Fatalf("DeleteProvidersBySerial: %v", err)
	}
	if n != 0 {
		t.Fatalf("rows_removed = %d, want 0 for non-owner", n)
	}
	if rec, _ := st.GetProviderBySerial(ctx, "SER"); rec == nil {
		t.Fatal("record deleted by non-owner")
	}
}
