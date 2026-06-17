package store

import (
	"context"
	"testing"
	"time"
)

// providerTrustReuseRoundTrip exercises the persistence contract the trust-reuse
// cache relies on (DAR-326 Phase 0), mirroring codeAttestRoundTrip: upsert is
// keyed by SE pubkey, list returns every row with all fields, delete removes a
// row, and a second upsert for the same key overwrites rather than duplicates.
func providerTrustReuseRoundTrip(t *testing.T, st Store) {
	t.Helper()
	ctx := context.Background()
	// Truncate to avoid sub-second/tz round-trip noise across backends.
	t0 := time.Now().UTC().Truncate(time.Second)

	// Empty SE key is a no-op (defensive — never persist an unkeyed row).
	if err := st.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{TrustLevel: "hardware", VerifiedAt: t0}); err != nil {
		t.Fatalf("upsert empty key: %v", err)
	}
	if rows, err := st.ListProviderTrustReuse(ctx); err != nil || len(rows) != 0 {
		t.Fatalf("empty-key upsert must not persist a row: rows=%d err=%v", len(rows), err)
	}

	recA := ProviderTrustReuse{
		SEPubKey:       "se-A",
		Serial:         "SER-A",
		TrustLevel:     "hardware",
		BinaryHash:     "aaaa",
		SIPEnabled:     true,
		SecureBootFull: true,
		MDAUDID:        "UDID-A",
		VerifiedAt:     t0,
	}
	if err := st.UpsertProviderTrustReuse(ctx, recA); err != nil {
		t.Fatalf("upsert A: %v", err)
	}
	if err := st.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{SEPubKey: "se-B", Serial: "SER-B", TrustLevel: "hardware", VerifiedAt: t0}); err != nil {
		t.Fatalf("upsert B: %v", err)
	}

	rows, err := st.ListProviderTrustReuse(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("len = %d, want 2", len(rows))
	}
	byKey := map[string]ProviderTrustReuse{}
	for _, r := range rows {
		byKey[r.SEPubKey] = r
	}
	got := byKey["se-A"]
	if got.Serial != "SER-A" || got.TrustLevel != "hardware" || got.BinaryHash != "aaaa" ||
		!got.SIPEnabled || !got.SecureBootFull || got.MDAUDID != "UDID-A" || !got.VerifiedAt.Equal(t0) {
		t.Fatalf("se-A round-trip mismatch: %+v", got)
	}

	// Upsert the same key with new values overwrites (no duplicate).
	t1 := t0.Add(10 * time.Minute)
	if err := st.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{
		SEPubKey: "se-A", Serial: "SER-A2", TrustLevel: "hardware", BinaryHash: "bbbb",
		SIPEnabled: true, SecureBootFull: false, MDAUDID: "UDID-A2", VerifiedAt: t1,
	}); err != nil {
		t.Fatalf("re-upsert A: %v", err)
	}
	rows, err = st.ListProviderTrustReuse(ctx)
	if err != nil {
		t.Fatalf("list after re-upsert: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("re-upsert must not duplicate: len = %d, want 2", len(rows))
	}
	for _, r := range rows {
		if r.SEPubKey == "se-A" && (r.Serial != "SER-A2" || r.BinaryHash != "bbbb" || r.SecureBootFull || r.MDAUDID != "UDID-A2" || !r.VerifiedAt.Equal(t1)) {
			t.Fatalf("se-A overwrite mismatch: %+v", r)
		}
	}

	// Delete removes one row; an empty-key delete is a no-op.
	if err := st.DeleteProviderTrustReuse(ctx, ""); err != nil {
		t.Fatalf("delete empty key: %v", err)
	}
	if err := st.DeleteProviderTrustReuse(ctx, "se-A"); err != nil {
		t.Fatalf("delete A: %v", err)
	}
	rows, err = st.ListProviderTrustReuse(ctx)
	if err != nil {
		t.Fatalf("list after delete: %v", err)
	}
	if len(rows) != 1 || rows[0].SEPubKey != "se-B" {
		t.Fatalf("after delete want only se-B, got %+v", rows)
	}
}

func TestMemoryProviderTrustReuseRoundTrip(t *testing.T) {
	providerTrustReuseRoundTrip(t, NewMemory(Config{}))
}

func TestPostgresProviderTrustReuseRoundTrip(t *testing.T) {
	providerTrustReuseRoundTrip(t, testPostgresStore(t))
}
