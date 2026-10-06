package postgres

import (
	"context"
	"fmt"
	"time"

	earningssql "github.com/eigeninference/d-inference/coordinator/internal/store/earningssql"
)

// ensureProviderEarningsWindowIndex builds the BRIN index behind the windowed
// network-totals and leaderboard aggregates, which filter provider_earnings on
// created_at >= $1 across all accounts; every other index on the table leads
// with an equality column, so those scans read the whole heap. BRIN rather
// than btree because earnings are inserted approximately in time order:
// block-range summaries can prune historical pages without a per-row index.
// Autosummarize keeps new ranges eligible for summarization as earnings arrive.
// The CONCURRENTLY build permits an old coordinator to continue writing.
func (s *PostgresStore) ensureProviderEarningsWindowIndex(ctx context.Context) error {
	started := time.Now()
	err := s.ensureConcurrentIndex(ctx, earningssql.WindowIndex,
		`CREATE INDEX CONCURRENTLY IF NOT EXISTS `+earningssql.WindowIndex+` ON provider_earnings USING brin (created_at) WITH (autosummarize = on)`)
	logStartupMigration(earningssql.WindowIndex, started, err)
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
	if current == earningssql.AnalyzeScaleFactor {
		return nil
	}
	if _, err := s.pool.Exec(ctx,
		`ALTER TABLE provider_earnings SET (autovacuum_analyze_scale_factor = `+earningssql.AnalyzeScaleFactor+`)`); err != nil {
		return fmt.Errorf("store: set provider_earnings analyze scale factor: %w", err)
	}
	return nil
}
