package postgres

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// Create all missing rows before taking any balance locks, then lock in account
// order. Interleaving row creation and locking can deadlock against another
// settlement that inserts a later account before waiting for an earlier one.
func lockSettlementBalances(ctx context.Context, tx pgx.Tx, accounts []string) error {
	if _, err := tx.Exec(ctx, `INSERT INTO balances(account_id,balance_micro_usd,withdrawable_micro_usd) SELECT DISTINCT x,0,0 FROM unnest($1::text[]) AS x ORDER BY x ON CONFLICT DO NOTHING`, accounts); err != nil {
		return err
	}
	rows, err := tx.Query(ctx, `SELECT account_id FROM balances WHERE account_id=ANY($1::text[]) ORDER BY account_id FOR UPDATE`, accounts)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
	}
	return rows.Err()
}
