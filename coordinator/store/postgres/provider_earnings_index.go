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
//   - Fast path: if a valid index already exists, return immediately (a
//     database that already has the index does no work here).
//   - It NEVER deletes rows. If existing data would violate uniqueness it fails
//     loudly with an actionable message rather than running a destructive,
//     table-locking cleanup at boot (the original outage).
//   - The build is CONCURRENTLY so a blue-green old coordinator still writing to
//     provider_earnings is never lock-blocked, and uses the simple query protocol
//     because CREATE INDEX CONCURRENTLY cannot run inside the extended protocol's
//     implicit transaction.
func (s *PostgresStore) ensureProviderEarningsJobIndex(ctx context.Context) error {
	const idxName = "idx_provider_earnings_job"

	// Already present AND valid? No-op fast path.
	exists, valid, err := concurrentIndexState(ctx, s.pool, idxName)
	if err != nil || valid {
		return err
	}
	if exists {
		return invalidConcurrentIndexError(idxName)
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

	return s.ensureConcurrentIndex(ctx, idxName,
		`CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_provider_earnings_job ON provider_earnings(job_id) WHERE job_id <> ''`)
}
