package store

import (
	"context"
	"fmt"
	"time"
)

const (
	providerEarningsWindowIndex = "idx_provider_earnings_created_at_brin"
	// providerEarningsAnalyzeScaleFactor re-analyzes provider_earnings after
	// 0.5% of its rows change (~0.7M at today's size) instead of the 10%
	// default (~14M). At ~4M inserts/day the default lets the created_at
	// histogram trail ingestion by days, and the planner then costs a 24h
	// window as a few thousand rows.
	providerEarningsAnalyzeScaleFactor = "0.005"
)

// ensureProviderEarningsWindowIndex builds the BRIN index behind the windowed
// network-totals and leaderboard aggregates, which filter provider_earnings on
// created_at >= $1 across all accounts; every other index on the table leads
// with an equality column, so those scans read the whole heap. BRIN rather
// than btree because the table is append-only in time order (created_at
// correlation ~0.997): the index is kilobytes, builds in about a minute, and
// is never preferred over a seq scan for the all-time window. The build is
// CONCURRENTLY so an old blue-green coordinator still writing is not blocked.
func (s *PostgresStore) ensureProviderEarningsWindowIndex(ctx context.Context) error {
	started := time.Now()
	err := s.ensureConcurrentIndex(ctx, providerEarningsWindowIndex,
		`CREATE INDEX CONCURRENTLY IF NOT EXISTS `+providerEarningsWindowIndex+` ON provider_earnings USING brin (created_at)`)
	logStartupMigration(providerEarningsWindowIndex, started, err)
	if err != nil {
		return err
	}
	return s.ensureProviderEarningsAnalyzeCadence(ctx)
}

// ensureProviderEarningsAnalyzeCadence pins the per-table analyze threshold so
// created_at statistics keep pace with ingestion. ALTER TABLE ... SET on an
// autovacuum option takes only SHARE UPDATE EXCLUSIVE; the write is skipped
// when the option already holds so a restart touches no catalog row.
func (s *PostgresStore) ensureProviderEarningsAnalyzeCadence(ctx context.Context) error {
	var current string
	if err := s.pool.QueryRow(ctx, `
		SELECT COALESCE((
			SELECT split_part(opt, '=', 2)
			FROM pg_class c, unnest(c.reloptions) AS opt
			WHERE c.oid = 'provider_earnings'::regclass
			  AND opt LIKE 'autovacuum_analyze_scale_factor=%'
		), '')`).Scan(&current); err != nil {
		return fmt.Errorf("store: inspect provider_earnings reloptions: %w", err)
	}
	if current == providerEarningsAnalyzeScaleFactor {
		return nil
	}
	if _, err := s.pool.Exec(ctx,
		`ALTER TABLE provider_earnings SET (autovacuum_analyze_scale_factor = `+providerEarningsAnalyzeScaleFactor+`)`); err != nil {
		return fmt.Errorf("store: set provider_earnings analyze scale factor: %w", err)
	}
	return nil
}
