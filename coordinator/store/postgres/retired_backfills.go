package postgres

import (
	"context"
	"fmt"
	"strings"

	backfills "github.com/eigeninference/d-inference/coordinator/internal/store/backfills"
)

// retiredBackfillRemedy tells the operator how to repair a database that
// skipped the retired backfills.
const retiredBackfillRemedy = "boot a coordinator built from v0.9.10 (which still runs them) " +
	"against this database once so it applies the retired backfills and records their markers, " +
	"then start this build"

// checkRetiredBackfills refuses to start on a database that still needs one of
// the retired backfills, and records their markers on a database that never
// will.
//
// A marker is recorded only while its data table is empty. With no history to
// rebuild, the current schema is already exact: balances is created with
// withdrawable_micro_usd, a zero usage counter matches an empty usage table,
// and every earning write maintains earnings_summary. v0.9.10 recorded the
// same markers on an empty database, so either binary boots afterwards. A
// table that holds rows without its marker belongs to a database that skipped
// the backfill. Serving it would leave withdrawable balances, lifetime usage
// totals or earnings summaries short of their history (and without the
// column, every balance write fails), so boot fails here instead.
//
// The usage counter row is seeded under the same empty-table condition. On a
// database with usage history it must come from backfill_usage_totals_v1:
// seeding zero there, then failing, would let v0.9.10 adopt the zero row as an
// already-exact counter.
func (s *PostgresStore) checkRetiredBackfills(ctx context.Context) error {
	// Check the column before recording anything: a withdrawable marker on a
	// balances table without the column would make v0.9.10 skip the ADD COLUMN.
	var hasWithdrawable bool
	if err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = current_schema()
			  AND table_name = 'balances'
			  AND column_name = 'withdrawable_micro_usd'
		)`).Scan(&hasWithdrawable); err != nil {
		return fmt.Errorf("store: inspect balances schema: %w", err)
	}
	if !hasWithdrawable {
		return fmt.Errorf("store: balances.withdrawable_micro_usd is missing (backfill_withdrawable_balance_v1 never ran); %s",
			retiredBackfillRemedy)
	}

	for _, b := range backfills.Retired {
		if _, err := s.pool.Exec(ctx, `
			INSERT INTO schema_migrations (id)
			SELECT $1 WHERE NOT EXISTS (SELECT 1 FROM `+b.DataTable+`)
			ON CONFLICT (id) DO NOTHING`, b.ID); err != nil {
			return fmt.Errorf("store: record %s on an empty %s table: %w", b.ID, b.DataTable, err)
		}
	}
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO usage_totals (id)
		SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM usage)
		ON CONFLICT (id) DO NOTHING`); err != nil {
		return fmt.Errorf("store: seed usage_totals counter: %w", err)
	}

	var missing []string
	for _, b := range backfills.Retired {
		var recorded bool
		if err := s.pool.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE id = $1)`, b.ID,
		).Scan(&recorded); err != nil {
			return fmt.Errorf("store: read %s marker: %w", b.ID, err)
		}
		if !recorded {
			missing = append(missing, fmt.Sprintf("%s (%s has rows)", b.ID, b.DataTable))
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("store: database holds data that retired backfills never processed: %s; %s",
			strings.Join(missing, ", "), retiredBackfillRemedy)
	}

	var hasCounter bool
	if err := s.pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM usage_totals WHERE id = 1)`,
	).Scan(&hasCounter); err != nil {
		return fmt.Errorf("store: read usage_totals counter: %w", err)
	}
	if !hasCounter {
		return fmt.Errorf("store: usage_totals counter row is missing although backfill_usage_totals_v1 is recorded; " +
			"restore the row from the usage history before starting")
	}
	return nil
}
