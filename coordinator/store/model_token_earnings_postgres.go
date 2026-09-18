package store

import (
	"context"
	"github.com/jackc/pgx/v5"
)

// Provider balance locks are already held, preserving the global balance lock
// order. Carry, grant consumption, earning and terminal record commit together.
func carryModelTokenEarningPostgres(ctx context.Context, tx pgx.Tx, earning *ModelTokenEarning) (*ProviderEarning, error) {
	if earning == nil {
		return nil, nil
	}
	if earning.FractionalMicroUSD == 0 {
		copy := earning.ProviderEarning
		return &copy, nil
	}
	if _, err := tx.Exec(ctx, `INSERT INTO model_token_provider_carries(account_id,remainder) VALUES($1,0) ON CONFLICT DO NOTHING`, earning.AccountID); err != nil {
		return nil, err
	}
	var carry int64
	if err := tx.QueryRow(ctx, `SELECT remainder FROM model_token_provider_carries WHERE account_id=$1 FOR UPDATE`, earning.AccountID).Scan(&carry); err != nil {
		return nil, err
	}
	credited, remaining, err := carryModelTokenEarning(earning, carry)
	if err != nil {
		return nil, err
	}
	_, err = tx.Exec(ctx, `UPDATE model_token_provider_carries SET remainder=$2 WHERE account_id=$1`, earning.AccountID, remaining)
	return credited, err
}
