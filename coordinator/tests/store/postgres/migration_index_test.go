package postgres_test

import (
	"context"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMigrationsRefuseInvalidStripeRefundIndex(t *testing.T) {
	ctx := context.Background()
	s, err := openPostgresFixture(ctx, store.Config{DatabaseURL: newThrowawayTestDatabase(t)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	pendingFrom(t, s, 9)
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_ledger_stripe_refund;
		INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		VALUES ('same-account', 'stripe_payout', -1, 0, 'same-reference'),
		       ('same-account', 'stripe_payout', -1, 0, 'same-reference')`); err != nil {
		t.Fatal(err)
	}
	// A failed real concurrent build leaves the named index invalid.
	if _, err := s.pool.Exec(ctx, `CREATE UNIQUE INDEX CONCURRENTLY idx_ledger_stripe_refund
		ON ledger_entries(account_id, reference)`); err == nil {
		t.Fatal("duplicate rows unexpectedly allowed a unique index")
	}
	if err := s.reopen(ctx); err == nil || !strings.Contains(err.Error(), "index idx_ledger_stripe_refund is invalid") {
		t.Fatalf("reopen with invalid refund index = %v", err)
	}
	var applied bool
	if err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM goose_db_version WHERE version_id = 9 AND is_applied)`).Scan(&applied); err != nil {
		t.Fatal(err)
	}
	if applied {
		t.Fatal("invalid refund index migration was recorded as applied")
	}
	// Repair is explicit; the migration does not drop the invalid index itself.
	if _, err := s.pool.Exec(ctx, `DROP INDEX idx_ledger_stripe_refund`); err != nil {
		t.Fatal(err)
	}
	if err := s.reopen(ctx); err != nil {
		t.Fatalf("reopen after explicit repair: %v", err)
	}
	var valid, unique bool
	if err := s.pool.QueryRow(ctx, `SELECT indisvalid AND indisready, indisunique
		FROM pg_index WHERE indexrelid = 'idx_ledger_stripe_refund'::regclass`).Scan(&valid, &unique); err != nil {
		t.Fatal(err)
	}
	if !valid || unique {
		t.Fatalf("repaired refund index valid=%v, unique=%v", valid, unique)
	}
}
