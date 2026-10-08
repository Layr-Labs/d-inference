package postgres_test

import (
	"context"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestWithdrawalFundingMigrationAdoptsExistingSchema(t *testing.T) {
	ctx := context.Background()
	databaseURL := newThrowawayTestDatabase(t)
	pool := openTestPool(t, databaseURL)
	loadSchemaFile(t, pool)
	if _, err := pool.Exec(ctx, `INSERT INTO stripe_withdrawals
 (id,account_id,stripe_account_id,amount_micro_usd,net_micro_usd,method,status,transfer_attempt,transfer_dispatch_attempts,transfer_started_at,transfer_lease_until)
 VALUES ('queued-migration','migration-account','acct_migration',8000000,8000000,'standard','queued',3,1,'2026-10-01 12:00:00+00','2026-10-01 12:05:00+00')`); err != nil {
		t.Fatal(err)
	}
	beforeSchema := schemaSnapshot(t, pool)
	const rowsSQL = `SELECT row_to_json(w)::text FROM stripe_withdrawals w WHERE id='queued-migration'`
	beforeRows := queryLines(t, pool, rowsSQL)
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		t.Fatalf("adopt schema containing withdrawal funding columns: %v", err)
	}
	t.Cleanup(s.Close)
	if err := s.reopen(ctx); err != nil {
		t.Fatalf("restart after schema adoption: %v", err)
	}
	assertSameLines(t, "queued record before adoption", beforeRows, "queued record after adoption", queryLines(t, pool, rowsSQL))
	assertSameLines(t, "schema before adoption", beforeSchema, "schema after adoption", schemaSnapshot(t, pool))
	var versions int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM goose_db_version WHERE version_id=27 AND is_applied`).Scan(&versions); err != nil {
		t.Fatal(err)
	}
	if versions != 1 {
		t.Fatalf("funding migration recorded %d times, want 1", versions)
	}
}
