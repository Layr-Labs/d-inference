package postgres

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/jackc/pgx/v5"
)

func (s *Store) CreateStripeWithdrawal(w *contracts.StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Now()
	if w.CreatedAt.IsZero() {
		w.CreatedAt = now
	}
	if w.UpdatedAt.IsZero() {
		w.UpdatedAt = w.CreatedAt
	}

	_, err := s.pool.Exec(ctx,
		`INSERT INTO stripe_withdrawals
		 (id, account_id, stripe_account_id, transfer_id, payout_id, sweep_payout_id,
		  amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
		  failure_reason, refunded, fee_refunded, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)`,
		w.ID, w.AccountID, w.StripeAccountID, w.TransferID, w.PayoutID, w.SweepPayoutID,
		w.AmountMicroUSD, w.FeeMicroUSD, w.NetMicroUSD, w.Method, w.Status,
		w.FailureReason, w.Refunded, w.FeeRefunded, w.CreatedAt, w.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("store: create stripe withdrawal: %w", err)
	}
	return nil
}

// CreateStripeWithdrawalWithDebit atomically debits both balance columns
// (recording the ledger entry) and inserts the withdrawal row in a single
// transaction — a crash can no longer leave a debited balance with no
// withdrawal row. Returns ErrInsufficientBalance when the guarded debit
// matches no row.
func (s *Store) CreateStripeWithdrawalWithDebit(w *contracts.StripeWithdrawal, entryType contracts.LedgerEntryType, reference string) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	if w.AmountMicroUSD <= 0 {
		return errors.New("stripe withdrawal amount must be positive")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	now := time.Now()
	if w.CreatedAt.IsZero() {
		w.CreatedAt = now
	}
	if w.UpdatedAt.IsZero() {
		w.UpdatedAt = w.CreatedAt
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("store: begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	// Same guarded dual-column debit as DebitWithdrawable: both the total
	// and withdrawable balances must cover the amount.
	var balanceAfter int64
	err = tx.QueryRow(ctx,
		`UPDATE balances
		 SET balance_micro_usd = balance_micro_usd - $2,
		     withdrawable_micro_usd = withdrawable_micro_usd - $2,
		     updated_at = NOW()
		 WHERE account_id = $1
		   AND balance_micro_usd >= $2
		   AND withdrawable_micro_usd >= $2
		 RETURNING balance_micro_usd`,
		w.AccountID, w.AmountMicroUSD,
	).Scan(&balanceAfter)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("store: insufficient withdrawable balance: %w", contracts.ErrInsufficientBalance)
		}
		return fmt.Errorf("store: withdrawal debit: %w", err)
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO ledger_entries (account_id, entry_type, amount_micro_usd, balance_after, reference)
		 VALUES ($1, $2, $3, $4, $5)`,
		w.AccountID, string(entryType), -w.AmountMicroUSD, balanceAfter, reference,
	); err != nil {
		return fmt.Errorf("store: insert ledger entry: %w", err)
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO stripe_withdrawals
		 (id, account_id, stripe_account_id, transfer_id, payout_id, sweep_payout_id,
		  amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
		  failure_reason, refunded, fee_refunded, created_at, updated_at)
		 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)`,
		w.ID, w.AccountID, w.StripeAccountID, w.TransferID, w.PayoutID, w.SweepPayoutID,
		w.AmountMicroUSD, w.FeeMicroUSD, w.NetMicroUSD, w.Method, w.Status,
		w.FailureReason, w.Refunded, w.FeeRefunded, w.CreatedAt, w.UpdatedAt,
	); err != nil {
		return fmt.Errorf("store: create stripe withdrawal: %w", err)
	}

	return tx.Commit(ctx)
}

const stripeWithdrawalSelectColumns = `id, account_id, stripe_account_id, transfer_id, payout_id, sweep_payout_id,
	amount_micro_usd, fee_micro_usd, net_micro_usd, method, status,
	failure_reason, refunded, fee_refunded, created_at, updated_at`

func scanStripeWithdrawal(row rowScanner) (*contracts.StripeWithdrawal, error) {
	var w contracts.StripeWithdrawal
	if err := row.Scan(&w.ID, &w.AccountID, &w.StripeAccountID, &w.TransferID, &w.PayoutID, &w.SweepPayoutID,
		&w.AmountMicroUSD, &w.FeeMicroUSD, &w.NetMicroUSD, &w.Method, &w.Status,
		&w.FailureReason, &w.Refunded, &w.FeeRefunded, &w.CreatedAt, &w.UpdatedAt); err != nil {
		return nil, err
	}
	return &w, nil
}

func (s *Store) GetStripeWithdrawal(id string) (*contracts.StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE id = $1`, id)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		return nil, fmt.Errorf("store: stripe withdrawal %q not found: %w", id, err)
	}
	return w, nil
}

func (s *Store) GetStripeWithdrawalByPayoutID(payoutID string) (*contracts.StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE payout_id = $1`, payoutID)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("store: stripe withdrawal with payout %q: %w", payoutID, contracts.ErrNotFound)
		}
		return nil, fmt.Errorf("store: get stripe withdrawal by payout %q: %w", payoutID, err)
	}
	return w, nil
}

func (s *Store) GetStripeWithdrawalByTransferID(transferID string) (*contracts.StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	row := s.pool.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE transfer_id = $1`, transferID)
	w, err := scanStripeWithdrawal(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("store: stripe withdrawal with transfer %q: %w", transferID, contracts.ErrNotFound)
		}
		return nil, fmt.Errorf("store: get stripe withdrawal by transfer %q: %w", transferID, err)
	}
	return w, nil
}

func (s *Store) UpdateStripeWithdrawal(w *contracts.StripeWithdrawal) error {
	if w == nil || w.ID == "" {
		return errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tag, err := s.pool.Exec(ctx,
		`UPDATE stripe_withdrawals SET
			transfer_id = $2, payout_id = $3, sweep_payout_id = $4, status = $5,
			failure_reason = $6, refunded = $7, fee_refunded = $8, updated_at = NOW()
		 WHERE id = $1`,
		w.ID, w.TransferID, w.PayoutID, w.SweepPayoutID, w.Status, w.FailureReason, w.Refunded, w.FeeRefunded,
	)
	if err != nil {
		return fmt.Errorf("store: update stripe withdrawal: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("stripe withdrawal %q not found", w.ID)
	}
	w.UpdatedAt = time.Now()
	return nil
}

func (s *Store) ListStripeWithdrawals(accountID string, limit int) ([]contracts.StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	q := `SELECT ` + stripeWithdrawalSelectColumns + ` FROM stripe_withdrawals WHERE account_id = $1 ORDER BY created_at DESC`
	args := []any{accountID}
	if limit > 0 {
		q += ` LIMIT $2`
		args = append(args, limit)
	}
	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals: %w", err)
	}
	defer rows.Close()

	var out []contracts.StripeWithdrawal
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	if out == nil {
		return []contracts.StripeWithdrawal{}, nil
	}
	return out, nil
}

// MarkStripeWithdrawalPaid atomically flips a non-terminal, non-refunded
// withdrawal to "paid" with an in-database guard (see interface doc).
func (s *Store) MarkStripeWithdrawalPaid(id, expectedPayoutID, sweepPayoutID string) (bool, error) {
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE stripe_withdrawals
		 SET status = 'paid',
		     sweep_payout_id = CASE WHEN $3 <> '' THEN $3 ELSE sweep_payout_id END,
		     updated_at = NOW()
		 WHERE id = $1
		   AND refunded = FALSE
		   AND status IN ('pending', 'transferred')
		   AND payout_id = $2`,
		id, expectedPayoutID, sweepPayoutID,
	)
	if err != nil {
		return false, fmt.Errorf("store: mark stripe withdrawal paid: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

// ReopenStripeWithdrawalAfterPayoutFailure atomically reopens a bounced
// withdrawal for sweep retry with an in-database guard (see interface doc).
func (s *Store) ReopenStripeWithdrawalAfterPayoutFailure(id, failureReason string, feeRefunded bool) (bool, error) {
	if id == "" {
		return false, errors.New("stripe withdrawal id is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	tag, err := s.pool.Exec(ctx,
		`UPDATE stripe_withdrawals
		 SET status = 'transferred',
		     payout_id = '',
		     failure_reason = $2,
		     fee_refunded = (fee_refunded OR $3),
		     updated_at = NOW()
		 WHERE id = $1
		   AND refunded = FALSE
		   AND status <> 'failed'`,
		id, failureReason, feeRefunded,
	)
	if err != nil {
		return false, fmt.Errorf("store: reopen stripe withdrawal: %w", err)
	}
	return tag.RowsAffected() > 0, nil
}

// ListStripeWithdrawalsBySweepPayoutID returns the rows stamped by the given
// automatic sweep payout, oldest first.
func (s *Store) ListStripeWithdrawalsBySweepPayoutID(sweepPayoutID string) ([]contracts.StripeWithdrawal, error) {
	if sweepPayoutID == "" {
		return []contracts.StripeWithdrawal{}, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals
		 WHERE sweep_payout_id = $1 ORDER BY created_at ASC`,
		sweepPayoutID)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals by sweep payout: %w", err)
	}
	defer rows.Close()

	out := []contracts.StripeWithdrawal{}
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	return out, nil
}

// ListStripeWithdrawalsByStatus returns up to limit withdrawals in the given
// status created before olderThan, oldest first. Limits <= 0 or above the cap
// are clamped to MaxStripeWithdrawalsByStatusLimit — never unbounded.
func (s *Store) ListStripeWithdrawalsByStatus(status string, olderThan time.Time, limit int) ([]contracts.StripeWithdrawal, error) {
	if limit <= 0 || limit > contracts.MaxStripeWithdrawalsByStatusLimit {
		limit = contracts.MaxStripeWithdrawalsByStatusLimit
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	q := `SELECT ` + stripeWithdrawalSelectColumns + ` FROM stripe_withdrawals
		 WHERE status = $1 AND created_at < $2 ORDER BY created_at ASC LIMIT $3`
	args := []any{status, olderThan, limit}
	rows, err := s.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals by status: %w", err)
	}
	defer rows.Close()

	out := []contracts.StripeWithdrawal{}
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	return out, nil
}

// ListStripeWithdrawalsForStripeAccount returns withdrawals destined for the
// given connected account in the given status, oldest first. Capped at
// MaxStripeWithdrawalsByStatusLimit as a webhook-path safety bound (a single
// account should never approach it; stragglers are picked up on redelivery
// or the next sweep since completed rows drop out of the status filter).
func (s *Store) ListStripeWithdrawalsForStripeAccount(stripeAccountID, status string) ([]contracts.StripeWithdrawal, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	rows, err := s.pool.Query(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals
		 WHERE stripe_account_id = $1 AND status = $2 ORDER BY created_at ASC LIMIT $3`,
		stripeAccountID, status, contracts.MaxStripeWithdrawalsByStatusLimit)
	if err != nil {
		return nil, fmt.Errorf("store: list stripe withdrawals for stripe account: %w", err)
	}
	defer rows.Close()

	out := []contracts.StripeWithdrawal{}
	for rows.Next() {
		w, err := scanStripeWithdrawal(rows)
		if err != nil {
			return nil, fmt.Errorf("store: scan stripe withdrawal: %w", err)
		}
		out = append(out, *w)
	}
	return out, nil
}

func (s *Store) RefundStripeWithdrawalAfterReversal(id, expectedTransferID string) (bool, error) {
	if id == "" || expectedTransferID == "" {
		return false, errors.New("stripe withdrawal and transfer ids are required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, fmt.Errorf("store: begin reversal: %w", err)
	}
	defer tx.Rollback(ctx)
	wd, err := scanStripeWithdrawal(tx.QueryRow(ctx,
		`SELECT `+stripeWithdrawalSelectColumns+` FROM stripe_withdrawals WHERE id = $1 FOR UPDATE`, id))
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, fmt.Errorf("stripe withdrawal %q: %w", id, contracts.ErrNotFound)
		}
		return false, fmt.Errorf("store: lock reversal withdrawal: %w", err)
	}
	if wd.Status == "paid" || wd.Refunded || wd.TransferID != expectedTransferID {
		return false, nil
	}
	refunds := payoutstate.StripeReversalRefunds(wd)
	// Lock both references before touching the account balance. Otherwise an
	// independent fee refund could hold its reference while waiting for our
	// balance lock, as this transaction waits for that same fee reference.
	for _, refund := range refunds {
		if refund.Amount > 0 {
			if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, string(contracts.LedgerRefund)+":"+refund.Reference); err != nil {
				return false, fmt.Errorf("store: lock reversal refund: %w", err)
			}
		}
	}
	for _, refund := range refunds {
		if refund.Amount > 0 {
			if _, err := creditWithdrawableOnceTx(ctx, tx, wd.AccountID, refund.Amount, contracts.LedgerRefund, refund.Reference); err != nil {
				return false, err
			}
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE stripe_withdrawals
		SET status = 'failed', refunded = TRUE,
		    fee_refunded = (fee_refunded OR fee_micro_usd > 0),
		    failure_reason = 'transfer_reversed', updated_at = NOW()
		WHERE id = $1`, id); err != nil {
		return false, fmt.Errorf("store: persist reversal: %w", err)
	}
	return true, tx.Commit(ctx)
}
