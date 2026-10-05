package postgres_test

import (
	"context"
	"testing"
	"time"
)

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
	if err := st.reopen(ctx); err != nil {
		t.Fatalf("first migration: %v", err)
	}
	if err := st.reopen(ctx); err != nil {
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
