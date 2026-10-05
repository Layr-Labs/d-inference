package postgres_test

import (
	"context"
	"strings"
	"testing"
	"time"

	backfills "github.com/eigeninference/d-inference/coordinator/internal/store/backfills"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5/pgxpool"
)

func bootRetiredBackfillStore(t *testing.T, databaseURL string) (*postgresFixture, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: databaseURL})
	if err == nil {
		t.Cleanup(s.Close)
	}
	return s, err
}

func mustBootRetiredBackfillStore(t *testing.T, databaseURL string) *postgresFixture {
	t.Helper()
	s, err := bootRetiredBackfillStore(t, databaseURL)
	if err != nil {
		t.Fatalf("openPostgresFixture: %v", err)
	}
	return s
}

func retiredBackfillMarkerRecorded(t *testing.T, s *postgresFixture, id string) bool {
	t.Helper()
	var recorded bool
	if err := s.pool.QueryRow(context.Background(),
		`SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE id = $1)`, id,
	).Scan(&recorded); err != nil {
		t.Fatalf("read marker %s: %v", id, err)
	}
	return recorded
}

func mustExecRetiredBackfill(t *testing.T, s *postgresFixture, sql string, args ...any) {
	t.Helper()
	if _, err := s.pool.Exec(context.Background(), sql, args...); err != nil {
		t.Fatalf("exec %q: %v", sql, err)
	}
}

// seedRetiredBackfillData writes a row into every table a retired backfill
// read from.
func seedRetiredBackfillData(t *testing.T, s *postgresFixture) {
	t.Helper()
	if err := s.CreditWithdrawable("acct-retired", 700, store.LedgerPayout, "retired-ref"); err != nil {
		t.Fatalf("CreditWithdrawable: %v", err)
	}
	s.RecordUsage(store.UsageRecord{ProviderID: "prov-retired", ConsumerKey: "consumer", Model: "model", PromptTokens: 11, CompletionTokens: 13})
	if err := s.RecordProviderEarning(&store.ProviderEarning{
		AccountID:      "acct-retired",
		ProviderID:     "prov-retired",
		ProviderKey:    "key-retired",
		JobID:          "job-retired",
		Model:          "model",
		AmountMicroUSD: 500,
		PromptTokens:   11,
	}); err != nil {
		t.Fatalf("RecordProviderEarning: %v", err)
	}
}

func TestRetiredBackfillGuardRecordsMarkersOnFreshDatabase(t *testing.T) {
	databaseURL := newThrowawayTestDatabase(t)
	s := mustBootRetiredBackfillStore(t, databaseURL)

	for _, b := range backfills.Retired {
		if !retiredBackfillMarkerRecorded(t, s, b.ID) {
			t.Fatalf("fresh database boot did not record %s", b.ID)
		}
	}
	seedRetiredBackfillData(t, s)
	totals, err := s.UsageTotals()
	if err != nil || totals.Requests != 1 {
		t.Fatalf("usage totals = %+v, %v; want the seeded counter to count the request", totals, err)
	}

	// The same database, now holding data in every retired-backfill table,
	// must keep booting.
	again := mustBootRetiredBackfillStore(t, databaseURL)
	if totals, err := again.UsageTotals(); err != nil || totals.Requests != 1 {
		t.Fatalf("usage totals after reboot = %+v, %v; want the counter preserved", totals, err)
	}
}

func TestRetiredBackfillGuardBootsProdShapedDatabase(t *testing.T) {
	databaseURL := newThrowawayTestDatabase(t)
	s := mustBootRetiredBackfillStore(t, databaseURL)
	seedRetiredBackfillData(t, s)

	// Reshape the database the way v0.9.10 left prod: markers recorded by the
	// backfills themselves (plus the earnings plan markers), the backfill
	// scratch tables, and a usage counter that is ahead of the usage table.
	mustExecRetiredBackfill(t, s, `DELETE FROM schema_migrations WHERE id LIKE 'backfill_%'`)
	for _, id := range []string{
		"backfill_withdrawable_balance_v1",
		"backfill_usage_totals_v1",
		"attempt_earnings_summary_backfill_v1",
		"prepare_earnings_summary_backfill_v1",
		"backfill_earnings_summary_v1",
	} {
		mustExecRetiredBackfill(t, s,
			`INSERT INTO schema_migrations (id, applied_at) VALUES ($1, NOW() - INTERVAL '30 days')`, id)
	}
	mustExecRetiredBackfill(t, s, `CREATE TABLE usage_totals_backfill_state (
		id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
		cutoff_id BIGINT NOT NULL
	)`)
	mustExecRetiredBackfill(t, s, `CREATE TABLE earnings_summary_backfill_pending (
		key TEXT NOT NULL, key_type TEXT NOT NULL,
		total_count BIGINT NOT NULL, total_micro_usd BIGINT NOT NULL,
		total_prompt_tokens BIGINT NOT NULL, total_completion_tokens BIGINT NOT NULL,
		PRIMARY KEY (key, key_type)
	)`)
	mustExecRetiredBackfill(t, s, `UPDATE usage_totals
		SET total_requests = 41, total_prompt_tokens = 4100, total_completion_tokens = 820
		WHERE id = 1`)
	s.Close()

	again := mustBootRetiredBackfillStore(t, databaseURL)
	totals, err := again.UsageTotals()
	if err != nil {
		t.Fatalf("UsageTotals: %v", err)
	}
	if totals.Requests != 41 || totals.PromptTokens != 4100 || totals.CompletionTokens != 820 {
		t.Fatalf("usage totals = %+v, want the backfilled counter untouched", totals)
	}
	if got := again.GetWithdrawableBalance("acct-retired"); got != 700 {
		t.Fatalf("withdrawable balance = %d, want 700", got)
	}
}

func TestRetiredBackfillGuardRefusesDataWithoutMarker(t *testing.T) {
	for _, b := range backfills.Retired {
		t.Run(b.ID, func(t *testing.T) {
			databaseURL := newThrowawayTestDatabase(t)
			s := mustBootRetiredBackfillStore(t, databaseURL)
			seedRetiredBackfillData(t, s)
			mustExecRetiredBackfill(t, s, `DELETE FROM schema_migrations WHERE id = $1`, b.ID)
			if b.ID == "backfill_usage_totals_v1" {
				// A database that never ran the usage backfill has no counter
				// row either.
				mustExecRetiredBackfill(t, s, `DELETE FROM usage_totals`)
			}
			s.Close()

			_, err := bootRetiredBackfillStore(t, databaseURL)
			if err == nil {
				t.Fatalf("openPostgresFixture booted a database whose %s rows never ran %s", b.DataTable, b.ID)
			}
			if !strings.Contains(err.Error(), b.ID) || !strings.Contains(err.Error(), "v0.9.10") {
				t.Fatalf("error does not name the marker and the remedy: %v", err)
			}

			// The failed boot must leave the database exactly as v0.9.10 needs
			// it to run the backfill: no marker, and no zero usage counter that
			// v0.9.10 would adopt as exact.
			inspect := testPostgresStoreAt(t, databaseURL)
			if retiredBackfillMarkerRecorded(t, inspect, b.ID) {
				t.Fatalf("failed boot recorded %s", b.ID)
			}
			if b.ID == "backfill_usage_totals_v1" {
				var rows int
				if err := inspect.pool.QueryRow(context.Background(),
					`SELECT count(*) FROM usage_totals`).Scan(&rows); err != nil {
					t.Fatalf("count usage_totals: %v", err)
				}
				if rows != 0 {
					t.Fatalf("failed boot seeded %d usage_totals row(s) over existing usage", rows)
				}
			}
		})
	}
}

func TestRetiredBackfillGuardRefusesBalancesWithoutWithdrawableColumn(t *testing.T) {
	databaseURL := newThrowawayTestDatabase(t)
	s := mustBootRetiredBackfillStore(t, databaseURL)
	// An empty pre-split balances table: no rows, so only the column is
	// missing.
	mustExecRetiredBackfill(t, s, `DELETE FROM schema_migrations WHERE id = 'backfill_withdrawable_balance_v1'`)
	mustExecRetiredBackfill(t, s, `ALTER TABLE balances DROP COLUMN withdrawable_micro_usd`)
	s.Close()

	_, err := bootRetiredBackfillStore(t, databaseURL)
	if err == nil || !strings.Contains(err.Error(), "withdrawable_micro_usd is missing") {
		t.Fatalf("openPostgresFixture error = %v, want the missing withdrawable column", err)
	}
	inspect := testPostgresStoreAt(t, databaseURL)
	if retiredBackfillMarkerRecorded(t, inspect, "backfill_withdrawable_balance_v1") {
		t.Fatal("failed boot recorded backfill_withdrawable_balance_v1, so v0.9.10 would skip adding the column")
	}
}

// testPostgresStoreAt opens a pool on databaseURL without running migrate, for
// inspecting a database whose boot failed.
func testPostgresStoreAt(t *testing.T, databaseURL string) *postgresFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatalf("open inspection pool: %v", err)
	}
	t.Cleanup(pool.Close)
	return bindPostgresFixture(pool)
}
