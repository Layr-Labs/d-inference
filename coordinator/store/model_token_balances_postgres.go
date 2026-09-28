package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

func promotionWithdrawableHold(ctx context.Context, tx pgx.Tx, account string, amount int64) (int64, error) {
	if amount == 0 {
		return 0, nil
	}
	var held int64
	err := tx.QueryRow(ctx, `SELECT LEAST($2,GREATEST($2-(balance_micro_usd-withdrawable_micro_usd),0)) FROM balances WHERE account_id=$1 FOR UPDATE`, account, amount).Scan(&held)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, nil
	}
	return held, err
}

func refundPromotionBalance(ctx context.Context, tx pgx.Tx, account string, amount, withdrawable int64, reference string) error {
	if err := creditBalance(ctx, tx, account, amount, LedgerRefund, reference, time.Time{}); err != nil {
		return err
	}
	if withdrawable > 0 {
		_, err := tx.Exec(ctx, `UPDATE balances SET withdrawable_micro_usd=withdrawable_micro_usd+$2 WHERE account_id=$1`, account, withdrawable)
		return err
	}
	return nil
}
