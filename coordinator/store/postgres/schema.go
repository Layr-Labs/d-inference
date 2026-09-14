package postgres

import (
	"context"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/postgres/schema"
)

// migrate executes the ordered schema and then the gated startup migrations.
func (s *Store) migrate(ctx context.Context) error {
	migrations := schema.Statements(rewardLedgerTypesSQLList())

	for i, m := range migrations {
		started := time.Now()
		_, err := s.pool.Exec(ctx, m)
		logStartupMigration(fmt.Sprintf("schema_statement_%03d", i), started, err)
		if err != nil {
			return fmt.Errorf("migration statement %d failed: %w", i, err)
		}
	}

	if err := s.migrateEarningsSummary(ctx); err != nil {
		return err
	}
	if err := s.ensureProviderRestoreIndexes(ctx); err != nil {
		return err
	}

	if err := s.migrateUsageTotals(ctx); err != nil {
		return err
	}

	if err := s.migrateWithdrawableBalance(ctx); err != nil {
		return err
	}

	// DAR-349: build the provider_earnings(job_id) partial unique index outside
	// the loop — CONCURRENTLY, duplicate-checked, and at most once — so coordinator
	// startup never runs a long, lock-holding data migration on this hot table.
	if err := s.ensureProviderEarningsJobIndex(ctx); err != nil {
		return err
	}
	return nil
}
