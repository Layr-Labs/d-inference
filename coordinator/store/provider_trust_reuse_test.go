package store

import (
	"context"
	"testing"
	"time"
)

func providerTrustReuseRoundTrip(t *testing.T, st Store) {
	t.Helper()
	ctx := context.Background()
	t0 := time.Now().UTC().Truncate(time.Second)

	if _, err := st.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{
		TrustLevel: "hardware", HardwareProofVerifiedAt: t0,
	}, 0); err != nil {
		t.Fatalf("upsert empty key: %v", err)
	}
	if rows, err := st.ListProviderTrustReuse(ctx); err != nil || len(rows) != 0 {
		t.Fatalf("empty-key upsert must not persist a row: rows=%d err=%v", len(rows), err)
	}

	recA := ProviderTrustReuse{
		SEPubKey: "se-A", Serial: "SER-A", TrustLevel: "hardware",
		LastVerifiedBinaryHash: "aaaa", SIPEnabled: true,
		SecureBootFull: true, MDAUDID: "UDID-A",
		HardwareProofVerifiedAt: t0,
	}
	if _, err := st.UpsertProviderTrustReuse(ctx, recA, 0); err != nil {
		t.Fatalf("upsert A: %v", err)
	}
	if _, err := st.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{
		SEPubKey: "se-B", Serial: "SER-B", TrustLevel: "hardware",
		HardwareProofVerifiedAt: t0,
	}, 0); err != nil {
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
	for _, row := range rows {
		byKey[row.SEPubKey] = row
	}
	got := byKey["se-A"]
	if got.Serial != "SER-A" || got.TrustLevel != "hardware" ||
		got.LastVerifiedBinaryHash != "aaaa" || !got.SIPEnabled ||
		!got.SecureBootFull || got.MDAUDID != "UDID-A" ||
		!got.HardwareProofVerifiedAt.Equal(t0) ||
		got.ApplicationProofVerifiedAt != nil {
		t.Fatalf("se-A round-trip mismatch: %+v", got)
	}

	t1 := t0.Add(10 * time.Minute)
	if _, err := st.UpsertProviderTrustReuse(ctx, ProviderTrustReuse{
		SEPubKey: "se-A", Serial: "SER-A2", TrustLevel: "hardware",
		LastVerifiedBinaryHash: "bbbb", SIPEnabled: true,
		SecureBootFull: false, MDAUDID: "UDID-A2",
		HardwareProofVerifiedAt: t1,
	}, 0); err != nil {
		t.Fatalf("re-upsert A: %v", err)
	}

	if _, err := st.RevokeProviderTrustReuse(ctx, "se-A", "roundtrip-revocation"); err != nil {
		t.Fatalf("revoke A: %v", err)
	}
	rows, err = st.ListProviderTrustReuse(ctx)
	if err != nil {
		t.Fatalf("list after revoke: %v", err)
	}
	byKey = map[string]ProviderTrustReuse{}
	for _, row := range rows {
		byKey[row.SEPubKey] = row
	}
	revoked := byKey["se-A"]
	if revoked.RevokedAt == nil || revoked.RevocationGeneration == 0 ||
		revoked.RevocationEventID != "roundtrip-revocation" {
		t.Fatalf("revoke must retain a monotonic tombstone: %+v", revoked)
	}

	// Model a lost commit response: retrying the same event must return the same
	// authoritative tombstone without advancing the generation.
	ambiguousRetry, err := st.RevokeProviderTrustReuse(
		ctx, "se-A", revoked.RevocationEventID)
	if err != nil ||
		ambiguousRetry.RevokedAt == nil ||
		ambiguousRetry.RevocationGeneration != revoked.RevocationGeneration ||
		ambiguousRetry.RevocationEventID != revoked.RevocationEventID {
		t.Fatalf("ambiguous-response retry changed revocation: authoritative=%+v err=%v",
			ambiguousRetry, err)
	}

	// An ordinary/late write cannot resurrect the identity.
	if result, err := st.UpsertProviderTrustReuse(ctx, recA, 0); err != nil || result.Applied {
		t.Fatalf("late upsert: %v", err)
	}
	rows, _ = st.ListProviderTrustReuse(ctx)
	for _, row := range rows {
		if row.SEPubKey == "se-A" && row.RevokedAt == nil {
			t.Fatalf("late upsert resurrected revoked evidence: %+v", row)
		}
	}

	// Only explicit full-device recovery at the observed generation can clear it.
	recovered, err := st.RecoverProviderTrustReuse(
		ctx, recA, revoked.RevocationGeneration)
	if err != nil || !recovered.Applied {
		t.Fatalf("recover: recovered=%+v err=%v", recovered, err)
	}
	rows, _ = st.ListProviderTrustReuse(ctx)
	for _, row := range rows {
		if row.SEPubKey == "se-A" && row.RevokedAt != nil {
			t.Fatalf("reviewed recovery did not clear tombstone: %+v", row)
		}
	}

	// Retrying the already-committed revocation event is a no-op and cannot
	// re-tombstone a later reviewed recovery.
	authoritative, err := st.RevokeProviderTrustReuse(
		ctx, "se-A", revoked.RevocationEventID)
	if err != nil ||
		authoritative.RevocationGeneration != revoked.RevocationGeneration ||
		authoritative.RevocationEventID != revoked.RevocationEventID {
		t.Fatalf("idempotent revoke retry: authoritative=%+v err=%v",
			authoritative, err)
	}
	rows, _ = st.ListProviderTrustReuse(ctx)
	for _, row := range rows {
		if row.SEPubKey == "se-A" &&
			(row.RevokedAt != nil ||
				row.RevocationGeneration != revoked.RevocationGeneration ||
				row.RevocationEventID != revoked.RevocationEventID) {
			t.Fatalf("same-event retry changed recovered row: %+v", row)
		}
	}

	// A distinct hard-untrust observed by a stale coordinator after recovery
	// cannot collide with the old event's numeric generation.
	distinct, err := st.RevokeProviderTrustReuse(
		ctx, "se-A", "stale-coordinator-revocation")
	if err != nil ||
		distinct.RevokedAt == nil ||
		distinct.RevocationGeneration != revoked.RevocationGeneration+1 ||
		distinct.RevocationEventID != "stale-coordinator-revocation" {
		t.Fatalf("distinct stale-coordinator revoke was collapsed: authoritative=%+v err=%v",
			distinct, err)
	}
}

func TestMemoryProviderTrustReuseRoundTripRevocationEvents(t *testing.T) {
	providerTrustReuseRoundTrip(t, NewMemory(Config{}))
}

func TestPostgresProviderTrustReuseRoundTripRevocationEvents(t *testing.T) {
	providerTrustReuseRoundTrip(t, testPostgresStore(t))
}

func TestPostgresProviderTrustReuseLegacyMigrationIsIdempotent(t *testing.T) {
	st := testPostgresStore(t)
	ctx := context.Background()
	for _, column := range []string{
		"last_verified_binary_hash", "hardware_proof_verified_at",
		"application_proof_verified_at", "evidence_generation",
		"revocation_generation", "revocation_event_id", "revoked_at",
	} {
		if _, err := st.pool.Exec(ctx,
			"ALTER TABLE provider_trust_reuse DROP COLUMN IF EXISTS "+column,
		); err != nil {
			t.Fatalf("drop %s: %v", column, err)
		}
	}
	verifiedAt := time.Now().UTC().Add(-20 * time.Minute).Truncate(time.Second)
	if _, err := st.pool.Exec(ctx,
		`INSERT INTO provider_trust_reuse
		 (se_pubkey, serial, trust_level, binary_hash, sip_enabled,
		  secure_boot_full, mda_udid, verified_at)
		 VALUES ('legacy-se','LEGACY','hardware','legacy-hash',TRUE,TRUE,'legacy-udid',$1)`,
		verifiedAt,
	); err != nil {
		t.Fatalf("insert legacy row: %v", err)
	}
	if err := st.migrate(ctx); err != nil {
		t.Fatalf("first migration: %v", err)
	}
	if err := st.migrate(ctx); err != nil {
		t.Fatalf("second migration: %v", err)
	}
	rows, err := st.ListProviderTrustReuse(ctx)
	if err != nil {
		t.Fatalf("list migrated row: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	got := rows[0]
	if !got.HardwareProofVerifiedAt.Equal(verifiedAt) ||
		got.LastVerifiedBinaryHash != "legacy-hash" ||
		got.ApplicationProofVerifiedAt != nil ||
		got.RevocationEventID != "" ||
		got.RevokedAt != nil {
		t.Fatalf("conservative legacy backfill mismatch: %+v", got)
	}
}
