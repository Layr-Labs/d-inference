package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"
	"github.com/jackc/pgx/v5"
)

var _ contracts.GlobalPayoutStore = (*Store)(nil)

func payoutContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}

func readPayoutJSON(row pgx.Row, out any) error {
	var data []byte
	if err := row.Scan(&data); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return contracts.ErrNotFound
		}
		return err
	}
	return json.Unmarshal(data, out)
}

func (s *Store) CreateGlobalPayoutQuote(p contracts.GlobalPayout) error {
	if err := payoutstate.ValidateGlobalQuote(p); err != nil {
		return err
	}
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	ctx, cancel := payoutContext()
	defer cancel()
	_, err = s.pool.Exec(ctx, `INSERT INTO global_payout_withdrawals(id,account_id,status,submitted_at,checked_at,lease_until,expires_at,data) VALUES($1,$2,$3,$4,$5,$6,$7,$8)`, p.ID, p.AccountID, p.Status, p.SubmittedAt, p.CheckedAt, p.LeaseUntil, p.ExpiresAt, data)
	return err
}

func (s *Store) GetGlobalPayout(id string) (*contracts.GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	var p contracts.GlobalPayout
	err := readPayoutJSON(s.pool.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1`, id), &p)
	return &p, err
}

func (s *Store) GetGlobalPayoutByExternalID(id string) (*contracts.GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	var p contracts.GlobalPayout
	err := readPayoutJSON(s.pool.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE external_id=$1 AND external_id<>''`, id), &p)
	return &p, err
}

func persistGlobalPayout(ctx context.Context, tx pgx.Tx, p contracts.GlobalPayout) error {
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE global_payout_withdrawals SET status=$2,external_id=$3,submitted_at=$4,checked_at=$5,lease_until=$6,expires_at=$7,data=$8 WHERE id=$1`, p.ID, p.Status, p.ExternalID, p.SubmittedAt, p.CheckedAt, p.LeaseUntil, p.ExpiresAt, data)
	return err
}

func globalPayoutLedger(ctx context.Context, tx pgx.Tx, p contracts.GlobalPayout, amount int64, kind contracts.LedgerEntryType, ref string) error {
	var after int64
	err := tx.QueryRow(ctx, `UPDATE balances SET balance_micro_usd=balance_micro_usd+$2,withdrawable_micro_usd=withdrawable_micro_usd+$2,updated_at=NOW()
 WHERE account_id=$1 AND balance_micro_usd+$2>=0 AND withdrawable_micro_usd+$2>=0 RETURNING balance_micro_usd`, p.AccountID, amount).Scan(&after)
	if errors.Is(err, pgx.ErrNoRows) {
		return contracts.ErrInsufficientBalance
	}
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO ledger_entries(account_id,entry_type,amount_micro_usd,balance_after,reference) VALUES($1,$2,$3,$4,$5)`, p.AccountID, string(kind), amount, after, ref)
	return err
}

func (s *Store) BeginGlobalPayout(accountID, id string, now time.Time) (*contracts.GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var p contracts.GlobalPayout
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1 AND account_id=$2 FOR UPDATE`, id, accountID), &p); err != nil {
		return nil, err
	}
	if p.Status != "quoted" {
		return &p, nil
	}
	if p.QuoteInvalidated || !p.ExpiresAt.After(now) {
		return nil, contracts.ErrPayoutQuoteExpired
	}
	var r contracts.GlobalRecipient
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_recipients WHERE account_id=$1 FOR SHARE`, accountID), &r); err != nil {
		return nil, err
	}
	if r.ID != p.RecipientGeneration || !r.Ready || r.RecipientID != p.RecipientID || r.PayoutMethodID != p.PayoutMethodID {
		return nil, contracts.ErrPayoutConflict
	}
	if err = globalPayoutLedger(ctx, tx, p, -p.AmountMicroUSD, contracts.LedgerStripePayout, "global_payout:"+id); err != nil {
		return nil, err
	}
	p.Status = "pending"
	p.SubmittedAt = now
	if err = persistGlobalPayout(ctx, tx, p); err != nil {
		return nil, err
	}
	return &p, tx.Commit(ctx)
}

// mutateGlobalPayout owns the row lock and atomic persistence of a payout change.
// A false callback result leaves the row untouched and rolls back; a true result
// commits both the row and any ledger writes made through the same transaction.
func (s *Store) mutateGlobalPayout(ctx context.Context, id string, mutate func(pgx.Tx, *contracts.GlobalPayout) (bool, error)) (bool, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var p contracts.GlobalPayout
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1 FOR UPDATE`, id), &p); err != nil {
		return false, err
	}
	changed, err := mutate(tx, &p)
	if err != nil || !changed {
		return false, err
	}
	if err = persistGlobalPayout(ctx, tx, p); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

func (s *Store) ClaimGlobalPayout(id string, now time.Time) (bool, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	return s.mutateGlobalPayout(ctx, id, func(_ pgx.Tx, p *contracts.GlobalPayout) (bool, error) {
		if p.Status == "quoted" || p.Refunded || p.RequiresManualReconciliation() || p.LeaseUntil.After(now) {
			return false, nil
		}
		if p.ExternalID == "" && p.Rejection == nil {
			p.DispatchAttempts++
		}
		p.LeaseUntil = now.Add(time.Minute)
		return true, nil
	})
}

func (s *Store) ApplyGlobalPayout(id string, r contracts.GlobalPayoutResult, now time.Time) error {
	ctx, cancel := payoutContext()
	defer cancel()
	_, err := s.mutateGlobalPayout(ctx, id, func(tx pgx.Tx, p *contracts.GlobalPayout) (bool, error) {
		refund, err := payoutstate.ApplyGlobalResult(p, r, now)
		if err != nil {
			return false, err
		}
		if refund {
			if err := globalPayoutLedger(ctx, tx, *p, p.AmountMicroUSD, contracts.LedgerRefund, "global_payout_refund:"+id); err != nil {
				return false, err
			}
		}
		return true, nil
	})
	return err
}

func (s *Store) listGlobalPayouts(query string, args ...any) ([]contracts.GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []contracts.GlobalPayout{}
	for rows.Next() {
		var p contracts.GlobalPayout
		if err := readPayoutJSON(rows, &p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func globalPayoutLimit(limit int) int {
	if limit < 1 || limit > 200 {
		return 200
	}
	return limit
}

func (s *Store) ListGlobalPayouts(accountID string, limit int) ([]contracts.GlobalPayout, error) {
	return s.listGlobalPayouts(`SELECT data FROM global_payout_withdrawals WHERE account_id=$1 AND status<>'quoted' ORDER BY submitted_at DESC LIMIT $2`, accountID, globalPayoutLimit(limit))
}

func (s *Store) ListGlobalPayoutsToReconcile(now time.Time, limit int) ([]contracts.GlobalPayout, error) {
	return s.listGlobalPayouts(`SELECT data FROM global_payout_withdrawals WHERE (status IN ('pending','processing') OR (status='posted' AND submitted_at>$1)) AND NOT (external_id='' AND COALESCE(data->>'rejection','')='' AND COALESCE(data->>'failure_code','')=$5) AND checked_at<=$2 AND lease_until<=$3 ORDER BY checked_at LIMIT $4`, now.Add(-90*24*time.Hour), now.Add(-time.Minute), now, globalPayoutLimit(limit), contracts.GlobalPayoutManualReview)
}
