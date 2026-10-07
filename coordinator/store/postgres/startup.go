package postgres

import (
	"context"
	"log/slog"
	"time"
)

// Log bounded labels only: SQL and query parameters can contain sensitive data.
func logStartupMigration(name string, started time.Time, err error) {
	result := "applied"
	if err != nil {
		result = "failed"
	}
	slog.Info("postgres startup phase", "phase", name, "result", result,
		"duration_ms", time.Since(started).Milliseconds())
}

func (s *PostgresStore) ensureProviderRestoreIndexes(ctx context.Context) error {
	for _, index := range []struct{ name, ddl string }{
		{"idx_providers_restore_serial", `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_providers_restore_serial ON providers(serial_number, last_seen DESC, id DESC) WHERE serial_number <> ''`},
		{"idx_providers_restore_se_key", `CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_providers_restore_se_key ON providers(se_public_key, last_seen DESC, id DESC) WHERE se_public_key <> ''`},
	} {
		started := time.Now()
		err := s.ensureConcurrentIndex(ctx, index.name, index.ddl)
		logStartupMigration(index.name, started, err)
		if err != nil {
			return err
		}
	}
	return nil
}

// The refund check is clock-independent and must not scan lifetime account history.
func (s *PostgresStore) ensureStripeRefundIndex(ctx context.Context) error {
	started := time.Now()
	err := s.ensureConcurrentIndex(ctx, "idx_ledger_stripe_refund",
		`CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ledger_stripe_refund ON ledger_entries(account_id, reference) WHERE entry_type IN ('refund','stripe_payout')`)
	logStartupMigration("idx_ledger_stripe_refund", started, err)
	return err
}
