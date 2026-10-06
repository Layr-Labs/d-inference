package postgres

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/postgres/storedb"
	"github.com/jackc/pgx/v5"
)

func rollbackErasureTx(tx pgx.Tx) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = tx.Rollback(ctx)
}

// Admission and erasure agree on the first lock, before any balance or
// withdrawal row. Accounts predating users remain usable; they cannot have an
// erasure request. Existing settlement callbacks keep their own row locks.
func lockAccountAdmission(ctx context.Context, tx pgx.Tx, accountID string) error {
	var deleted *time.Time
	err := tx.QueryRow(ctx, `SELECT deleted_at FROM users WHERE account_id=$1 FOR SHARE`, accountID).Scan(&deleted)
	if noRows(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if deleted != nil {
		return store.ErrErasureConflict
	}
	return nil
}

func lockErasurePayments(ctx context.Context, q *storedb.Queries, accountID string) error {
	if _, err := q.LockAccountBillingSessions(ctx, accountID); err != nil {
		return err
	}
	if _, err := q.LockAccountStripeWithdrawals(ctx, accountID); err != nil {
		return err
	}
	if _, err := q.LockAccountGlobalPayouts(ctx, accountID); err != nil {
		return err
	}
	_, err := q.LockAccountGlobalRecipient(ctx, accountID)
	return err
}
