package store

import (
	"context"
	"testing"
	"time"
)

// codeAttestRoundTrip exercises the persistence contract the code-identity reuse
// cache relies on (W5 Fix 2): upsert is keyed by SE pubkey, list returns every
// row, and a second upsert for the same key overwrites rather than duplicates.
func codeAttestRoundTrip(t *testing.T, st Store) {
	t.Helper()
	ctx := context.Background()
	// Truncate to avoid sub-second/tz round-trip noise across backends.
	t0 := time.Now().UTC().Truncate(time.Second)

	// Empty SE key is a no-op (defensive — never persist an unkeyed row).
	if err := st.UpsertCodeAttestation(ctx, CodeAttestation{Version: "0.6.0", AttestedAt: t0}); err != nil {
		t.Fatalf("upsert empty key: %v", err)
	}
	if rows, err := st.ListCodeAttestations(ctx); err != nil || len(rows) != 0 {
		t.Fatalf("empty-key upsert must not persist a row: rows=%d err=%v", len(rows), err)
	}

	if err := st.UpsertCodeAttestation(ctx, CodeAttestation{SEPubKey: "se-A", Version: "0.6.0", AttestedAt: t0, APNsToken: "tok-A"}); err != nil {
		t.Fatalf("upsert A: %v", err)
	}
	if err := st.UpsertCodeAttestation(ctx, CodeAttestation{SEPubKey: "se-B", Version: "0.6.1", AttestedAt: t0}); err != nil {
		t.Fatalf("upsert B: %v", err)
	}

	rows, err := st.ListCodeAttestations(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("len = %d, want 2", len(rows))
	}
	byKey := map[string]CodeAttestation{}
	for _, r := range rows {
		byKey[r.SEPubKey] = r
	}
	if got := byKey["se-A"]; got.Version != "0.6.0" || !got.AttestedAt.Equal(t0) || got.APNsToken != "tok-A" {
		t.Fatalf("se-A round-trip mismatch: %+v", got)
	}

	// Upsert the same key with a newer time+version overwrites (no duplicate).
	t1 := t0.Add(10 * time.Minute)
	if err := st.UpsertCodeAttestation(ctx, CodeAttestation{SEPubKey: "se-A", Version: "0.6.2", AttestedAt: t1, APNsToken: "tok-A2"}); err != nil {
		t.Fatalf("re-upsert A: %v", err)
	}
	rows, err = st.ListCodeAttestations(ctx)
	if err != nil {
		t.Fatalf("list after re-upsert: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("re-upsert must not duplicate: len = %d, want 2", len(rows))
	}
	for _, r := range rows {
		if r.SEPubKey == "se-A" && (r.Version != "0.6.2" || !r.AttestedAt.Equal(t1) || r.APNsToken != "tok-A2") {
			t.Fatalf("se-A overwrite mismatch: %+v", r)
		}
	}
}

func TestMemoryCodeAttestationRoundTrip(t *testing.T) {
	codeAttestRoundTrip(t, NewMemory(Config{}))
}

func TestPostgresCodeAttestationRoundTrip(t *testing.T) {
	codeAttestRoundTrip(t, testPostgresStore(t))
}
