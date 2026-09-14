package postgres

import (
	"context"
	"fmt"
)

// ensureProviderEarningsJobIndex creates the partial UNIQUE index that backs the
// `ON CONFLICT (job_id) WHERE job_id <> ” DO NOTHING` idempotency used by
// RecordProviderEarning and CreditProviderAccount.
//
// DAR-349: this MUST stay cheap and non-blocking on the serving startup path.
//   - Fast path: if a valid index already exists, return immediately (every boot
//     after the first does no work here).
//   - It NEVER deletes rows. If existing data would violate uniqueness it fails
//     loudly with an actionable message rather than running a destructive,
//     table-locking cleanup at boot (the original outage).
//   - The build is CONCURRENTLY so a blue-green old coordinator still writing to
//     provider_earnings is never lock-blocked, and uses the simple query protocol
//     because CREATE INDEX CONCURRENTLY cannot run inside the extended protocol's
//     implicit transaction.
func (s *Store) ensureProviderEarningsJobIndex(ctx context.Context) error {
	const idxName = "idx_provider_earnings_job"

	// Already present AND valid? No-op fast path for every boot after the first.
	var valid bool
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE((
			SELECT i.indisvalid
			FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid
			WHERE c.relname = $1
		), false)`, idxName).Scan(&valid); err != nil {
		return fmt.Errorf("store: check %s: %w", idxName, err)
	}
	if valid {
		return nil
	}

	// A leftover *invalid* index from a previously interrupted CONCURRENTLY build
	// would make CREATE ... IF NOT EXISTS a silent no-op, so drop it first.
	if _, err := s.pool.Exec(ctx, `DROP INDEX IF EXISTS `+idxName); err != nil {
		return fmt.Errorf("store: drop invalid %s: %w", idxName, err)
	}

	// Verify the data can support a UNIQUE index. We do NOT dedupe at boot.
	var dupGroups int64
	if err := s.pool.QueryRow(ctx, `
		SELECT count(*) FROM (
			SELECT 1 FROM provider_earnings
			WHERE job_id <> '' GROUP BY job_id HAVING count(*) > 1
		) d`).Scan(&dupGroups); err != nil {
		return fmt.Errorf("store: count duplicate provider_earnings job_ids: %w", err)
	}
	if dupGroups > 0 {
		return fmt.Errorf("store: %d duplicate provider_earnings.job_id group(s) block unique index %s; "+
			"run the offline dedupe (coordinator/store/postgres/migrations/dedupe_provider_earnings.sql) before deploying "+
			"— boot does NOT auto-dedupe (DAR-349)", dupGroups, idxName)
	}

	// Build CONCURRENTLY on a dedicated connection via the simple query protocol.
	conn, err := s.pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("store: acquire conn for %s: %w", idxName, err)
	}
	defer conn.Release()
	mrr := conn.Conn().PgConn().Exec(ctx,
		`CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_provider_earnings_job ON provider_earnings(job_id) WHERE job_id <> ''`)
	if _, err := mrr.ReadAll(); err != nil {
		return fmt.Errorf("store: create %s concurrently: %w", idxName, err)
	}
	return nil
}
