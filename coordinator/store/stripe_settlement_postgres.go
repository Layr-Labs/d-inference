package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

func (s *PostgresStore) RecordStripeTransferRejection(id, reason string) error {
	if reason == "" {
		return ErrPayoutConflict
	}
	ctx, cancel := payoutContext()
	defer cancel()
	r, err := s.pool.Exec(ctx, `UPDATE stripe_withdrawals SET status='failed', failure_reason=$2, updated_at=NOW()
 WHERE id=$1 AND NOT refunded AND transfer_id='' AND payout_id='' AND sweep_payout_id=''
 AND (status='pending' OR (status='failed' AND failure_reason LIKE 'transfer_create_failed:%'))`, id, StripeConfirmedRejectionPrefix+reason)
	if err == nil && r.RowsAffected() != 1 {
		return ErrPayoutConflict
	}
	return err
}

func (s *PostgresStore) RefundRejectedStripeWithdrawal(id string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	w, err := scanStripeWithdrawal(tx.QueryRow(ctx, `SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE id=$1 FOR UPDATE`, id))
	if err != nil {
		return false, err
	}
	if w.Refunded {
		return false, nil
	}
	if !StripeRefundRecoverable(w) {
		return false, ErrPayoutConflict
	}
	ref := "stripe_withdraw:" + id
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, string(LedgerRefund)+":"+ref); err != nil {
		return false, err
	}
	// Existing callers use the same advisory lock and reference. Include time to
	// bound the lookup on the (account_id, created_at) index for busy providers.
	var credited, debited int64
	err = tx.QueryRow(ctx, `SELECT COALESCE(SUM(amount_micro_usd) FILTER (WHERE entry_type='refund'),0), COALESCE(SUM(amount_micro_usd) FILTER (WHERE entry_type='stripe_payout'),0) FROM ledger_entries WHERE account_id=$1 AND reference=$2 AND created_at >= $3 AND entry_type IN ('refund','stripe_payout')`, w.AccountID, ref, w.CreatedAt).Scan(&credited, &debited)
	if err != nil {
		return false, err
	}
	if debited != -w.AmountMicroUSD || (credited != 0 && credited != w.AmountMicroUSD) {
		return false, ErrPayoutConflict
	}
	if credited == 0 {
		if err = creditWithdrawableBalance(ctx, tx, w.AccountID, w.AmountMicroUSD, LedgerRefund, ref, time.Time{}); err != nil {
			return false, err
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE stripe_withdrawals SET refunded=TRUE, updated_at=NOW() WHERE id=$1`, id); err != nil {
		return false, err
	}
	return credited == 0, tx.Commit(ctx)
}

func (s *PostgresStore) CompleteStripeCheckout(id, externalID, accountID string, amount int64) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var b BillingSession
	err = tx.QueryRow(ctx, `SELECT account_id, payment_method, amount_micro_usd, external_id, status, created_at FROM billing_sessions WHERE id=$1 FOR UPDATE`, id).Scan(&b.AccountID, &b.PaymentMethod, &b.AmountMicroUSD, &b.ExternalID, &b.Status, &b.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	if err != nil {
		return false, err
	}
	if !checkoutMatches(&b, externalID, accountID, amount) {
		return false, ErrPayoutConflict
	}
	if b.Status == "completed" {
		return false, nil
	}
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, "stripe_checkout:"+externalID); err != nil {
		return false, err
	}
	var credited int64
	if err = tx.QueryRow(ctx, `SELECT COALESCE(SUM(amount_micro_usd),0) FROM ledger_entries WHERE account_id=$1 AND entry_type=$2 AND reference=$3`, accountID, string(LedgerStripeDeposit), "stripe:"+externalID).Scan(&credited); err != nil {
		return false, err
	}
	if credited != 0 && credited != amount {
		return false, ErrPayoutConflict
	}
	if credited == 0 {
		if err = creditBalance(ctx, tx, accountID, amount, LedgerStripeDeposit, "stripe:"+externalID, time.Time{}); err != nil {
			return false, err
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE billing_sessions SET status='completed', completed_at=NOW() WHERE id=$1`, id); err != nil {
		return false, err
	}
	return credited == 0, tx.Commit(ctx)
}

func (s *PostgresStore) ListStripeRefundsToRecover(limit int) ([]StripeWithdrawal, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	if limit <= 0 || limit > MaxStripeWithdrawalsByStatusLimit {
		limit = MaxStripeWithdrawalsByStatusLimit
	}
	rows, err := s.pool.Query(ctx, `SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE status='failed' AND NOT refunded AND transfer_id='' AND payout_id='' AND sweep_payout_id='' AND amount_micro_usd>0 AND starts_with(failure_reason,$1) ORDER BY updated_at LIMIT $2`, StripeConfirmedRejectionPrefix, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []StripeWithdrawal{}
	for rows.Next() {
		w, e := scanStripeWithdrawal(rows)
		if e != nil {
			return nil, e
		}
		out = append(out, *w)
	}
	return out, rows.Err()
}
