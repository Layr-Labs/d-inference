package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) ReleaseModelTokenReservation(id string) (bool, error) {
	return s.releaseModelTokenBefore(id, time.Time{})
}

func (s *PostgresStore) releaseModelTokenBefore(id string, before time.Time) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	r, err := lockPromotionReservation(ctx, tx, id)
	if err != nil {
		return false, err
	}
	if r == nil || r.State != "reserved" || (!before.IsZero() && !r.TouchedAt.Before(before)) {
		return false, nil
	}
	if _, err = tx.Exec(ctx, `UPDATE model_token_grants SET reserved_tokens=reserved_tokens-$3 WHERE account_id=$1 AND model_id=$2`, r.AccountID, r.ModelID, r.FreeTokens); err != nil {
		return false, err
	}
	if r.ReservedMicroUSD > 0 {
		if err = refundPromotionBalance(ctx, tx, r.AccountID, r.ReservedMicroUSD, r.ReservedWithdrawableMicroUSD, "promotion-release:"+id); err != nil {
			return false, err
		}
	}
	r.State = "released"
	if err = savePromotionReservation(ctx, tx, *r); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// Lock both balance rows in account order before debiting/refunding/crediting.
// This keeps two consumer/providers serving each other from forming a cycle.
func lockPromotionBalances(ctx context.Context, tx pgx.Tx, consumer string, earning *ModelTokenEarning) error {
	accounts := []string{consumer}
	if earning != nil && earning.AccountID != consumer {
		accounts = append(accounts, earning.AccountID)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO balances(account_id,balance_micro_usd,withdrawable_micro_usd) SELECT x,0,0 FROM unnest($1::text[]) AS x ORDER BY x ON CONFLICT DO NOTHING`, accounts); err != nil {
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

func (s *PostgresStore) SettleModelTokenReservation(id string, actual int64, quote ModelTokenQuote, earning *ModelTokenEarning) (ModelTokenSettlement, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return ModelTokenSettlement{}, err
	}
	defer tx.Rollback(ctx)
	r, err := lockPromotionReservation(ctx, tx, id)
	if err != nil {
		return ModelTokenSettlement{}, err
	}
	if r == nil {
		return ModelTokenSettlement{}, ErrNotFound
	}
	if r.State != "reserved" {
		return ModelTokenSettlement{Reservation: *r}, nil
	}
	next, err := promotionSettlement(*r, actual, quote, earning)
	if err != nil {
		return ModelTokenSettlement{}, err
	}
	if _, err = tx.Exec(ctx, `UPDATE model_token_grants SET reserved_tokens=reserved_tokens-$3,used_tokens=used_tokens+$4 WHERE account_id=$1 AND model_id=$2`, r.AccountID, r.ModelID, r.FreeTokens, next.UsedTokens); err != nil {
		return ModelTokenSettlement{}, err
	}
	if err = lockPromotionBalances(ctx, tx, r.AccountID, earning); err != nil {
		return ModelTokenSettlement{}, err
	}
	delta := next.ConsumerCostMicroUSD - r.ReservedMicroUSD
	if delta > 0 {
		err = debitBalance(ctx, tx, r.AccountID, delta, LedgerCharge, "promotion-settle:"+id)
	}
	if delta < 0 {
		err = refundPromotionBalance(ctx, tx, r.AccountID, -delta, min(-delta, r.ReservedWithdrawableMicroUSD), "promotion-settle:"+id)
	}
	if err != nil {
		return ModelTokenSettlement{}, err
	}
	credited, err := carryModelTokenEarningPostgres(ctx, tx, earning)
	if err != nil {
		return ModelTokenSettlement{}, err
	}
	if credited != nil {
		next.ProviderPayoutMicroUSD = credited.AmountMicroUSD
		if credited.AmountMicroUSD > 0 {
			if err = creditProviderAccount(ctx, tx, credited); err != nil {
				return ModelTokenSettlement{}, err
			}
		}
	}
	if err = savePromotionReservation(ctx, tx, next); err != nil {
		return ModelTokenSettlement{}, err
	}
	if err = tx.Commit(ctx); err != nil {
		return ModelTokenSettlement{}, err
	}
	return ModelTokenSettlement{Reservation: next, Applied: true}, nil
}
