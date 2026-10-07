package postgres

import (
	"errors"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/jackc/pgx/v5"
	"time"
)

func (s *PostgresStore) QueueStripeWithdrawal(id string, attempt int) error {
	ctx, cancel := payoutContext()
	defer cancel()
	tag, err := s.pool.Exec(ctx, `UPDATE stripe_withdrawals SET status='queued',failure_reason=$3,transfer_lease_until='0001-01-01 00:00:00+00',updated_at=NOW()
 WHERE id=$1 AND transfer_attempt=$2 AND transfer_dispatch_attempts<=1 AND status='pending' AND NOT refunded AND transfer_id='' AND payout_id='' AND sweep_payout_id=''`, id, attempt, store.WithdrawalFundingReason)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return store.ErrPayoutConflict
	}
	return nil
}

const stripeQueuePredicate = `NOT refunded AND transfer_id='' AND payout_id='' AND sweep_payout_id='' AND transfer_lease_until<=$1 AND (status='queued' OR (status='pending' AND transfer_attempt>0 AND transfer_started_at>$2))`

func (s *PostgresStore) ClaimStripeWithdrawal(id string, now time.Time) (*store.StripeWithdrawal, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	w, err := scanStripeWithdrawal(s.pool.QueryRow(ctx, `UPDATE stripe_withdrawals SET
 transfer_dispatch_attempts=CASE WHEN status='queued' THEN 1 ELSE transfer_dispatch_attempts+1 END,
 transfer_attempt=transfer_attempt+CASE WHEN status='queued' THEN 1 ELSE 0 END,
 transfer_started_at=CASE WHEN status='queued' THEN $1 ELSE transfer_started_at END,
 failure_reason=CASE WHEN status='queued' THEN '' ELSE failure_reason END,
 status='pending',transfer_lease_until=$4 WHERE id=$3 AND `+stripeQueuePredicate+` RETURNING `+stripeWithdrawalSelectColumns, now, now.Add(-12*time.Hour), id, now.Add(5*time.Minute)))
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return w, err
}

func (s *PostgresStore) ListStripeWithdrawalQueue(now time.Time, limit int) ([]store.StripeWithdrawal, error) {
	if limit <= 0 || limit > 200 {
		limit = 200
	}
	ctx, cancel := payoutContext()
	defer cancel()
	rows, err := s.pool.Query(ctx, `SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE `+stripeQueuePredicate+` ORDER BY updated_at LIMIT $3`, now, now.Add(-12*time.Hour), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []store.StripeWithdrawal{}
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *w)
	}
	return out, rows.Err()
}
