package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

var _ GlobalPayoutStore = (*PostgresStore)(nil)

const globalPayoutSchema = `
CREATE TABLE IF NOT EXISTS global_payout_recipients (
 account_id TEXT PRIMARY KEY, country TEXT NOT NULL, data JSONB NOT NULL
);
CREATE TABLE IF NOT EXISTS global_payout_withdrawals (
 id TEXT PRIMARY KEY, account_id TEXT NOT NULL, status TEXT NOT NULL,
 external_id TEXT NOT NULL DEFAULT '', submitted_at TIMESTAMPTZ NOT NULL,
 checked_at TIMESTAMPTZ NOT NULL, lease_until TIMESTAMPTZ NOT NULL, expires_at TIMESTAMPTZ NOT NULL, data JSONB NOT NULL
);
ALTER TABLE global_payout_withdrawals ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ NOT NULL DEFAULT 'infinity';
UPDATE global_payout_withdrawals SET expires_at=(data->>'expires_at')::timestamptz WHERE status='quoted' AND expires_at='infinity';
CREATE INDEX IF NOT EXISTS global_payout_quote_expiry ON global_payout_withdrawals(expires_at) WHERE status='quoted';
CREATE UNIQUE INDEX IF NOT EXISTS global_payout_external_id ON global_payout_withdrawals(external_id) WHERE external_id <> '';
CREATE INDEX IF NOT EXISTS global_payout_account ON global_payout_withdrawals(account_id, submitted_at DESC);
CREATE INDEX IF NOT EXISTS global_payout_reconcile ON global_payout_withdrawals(checked_at) WHERE status IN ('pending','processing','posted');
`

func payoutContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 5*time.Second)
}
func readPayoutJSON(row pgx.Row, out any) error {
	var data []byte
	if err := row.Scan(&data); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	return json.Unmarshal(data, out)
}

func (s *PostgresStore) CreateGlobalPayoutQuote(p GlobalPayout) error {
	if err := validateGlobalQuote(p); err != nil {
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
func (s *PostgresStore) GetGlobalPayout(id string) (*GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	var p GlobalPayout
	err := readPayoutJSON(s.pool.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1`, id), &p)
	return &p, err
}
func (s *PostgresStore) GetGlobalPayoutByExternalID(id string) (*GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	var p GlobalPayout
	err := readPayoutJSON(s.pool.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE external_id=$1 AND external_id<>''`, id), &p)
	return &p, err
}
func persistGlobalPayout(ctx context.Context, tx pgx.Tx, p GlobalPayout) error {
	data, err := json.Marshal(p)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE global_payout_withdrawals SET status=$2,external_id=$3,submitted_at=$4,checked_at=$5,lease_until=$6,expires_at=$7,data=$8 WHERE id=$1`, p.ID, p.Status, p.ExternalID, p.SubmittedAt, p.CheckedAt, p.LeaseUntil, p.ExpiresAt, data)
	return err
}
func globalPayoutLedger(ctx context.Context, tx pgx.Tx, p GlobalPayout, amount int64, kind LedgerEntryType, ref string) error {
	var after int64
	err := tx.QueryRow(ctx, `UPDATE balances SET balance_micro_usd=balance_micro_usd+$2,withdrawable_micro_usd=withdrawable_micro_usd+$2,updated_at=NOW()
 WHERE account_id=$1 AND balance_micro_usd+$2>=0 AND withdrawable_micro_usd+$2>=0 RETURNING balance_micro_usd`, p.AccountID, amount).Scan(&after)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrInsufficientBalance
	}
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `INSERT INTO ledger_entries(account_id,entry_type,amount_micro_usd,balance_after,reference) VALUES($1,$2,$3,$4,$5)`, p.AccountID, string(kind), amount, after, ref)
	return err
}
func (s *PostgresStore) BeginGlobalPayout(accountID, id string, now time.Time) (*GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var p GlobalPayout
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1 AND account_id=$2 FOR UPDATE`, id, accountID), &p); err != nil {
		return nil, err
	}
	if p.Status != "quoted" {
		return &p, nil
	}
	if !p.ExpiresAt.After(now) {
		return nil, ErrPayoutQuoteExpired
	}
	var r GlobalRecipient
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_recipients WHERE account_id=$1 FOR SHARE`, accountID), &r); err != nil {
		return nil, err
	}
	if r.ID != p.RecipientGeneration || !r.Ready || r.RecipientID != p.RecipientID || r.PayoutMethodID != p.PayoutMethodID {
		return nil, ErrPayoutConflict
	}
	if err = globalPayoutLedger(ctx, tx, p, -p.AmountMicroUSD, LedgerStripePayout, "global_payout:"+id); err != nil {
		return nil, err
	}
	p.Status = "pending"
	p.SubmittedAt = now
	if err = persistGlobalPayout(ctx, tx, p); err != nil {
		return nil, err
	}
	return &p, tx.Commit(ctx)
}
func (s *PostgresStore) ClaimGlobalPayout(id string, now time.Time) (bool, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var p GlobalPayout
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1 FOR UPDATE`, id), &p); err != nil {
		return false, err
	}
	if p.Status == "quoted" || p.Refunded || p.LeaseUntil.After(now) {
		return false, nil
	}
	if p.ExternalID == "" && p.Rejection == nil {
		p.DispatchAttempts++
	}
	p.LeaseUntil = now.Add(time.Minute)
	if err = persistGlobalPayout(ctx, tx, p); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}
func (s *PostgresStore) ApplyGlobalPayout(id string, r GlobalPayoutResult, now time.Time) error {
	ctx, cancel := payoutContext()
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var p GlobalPayout
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1 FOR UPDATE`, id), &p); err != nil {
		return err
	}
	refund, err := applyGlobalResult(&p, r, now)
	if err != nil {
		return err
	}
	if refund {
		if err = globalPayoutLedger(ctx, tx, p, p.AmountMicroUSD, LedgerRefund, "global_payout_refund:"+id); err != nil {
			return err
		}
	}
	if err = persistGlobalPayout(ctx, tx, p); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
func (s *PostgresStore) listGlobalPayouts(query string, args ...any) ([]GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []GlobalPayout{}
	for rows.Next() {
		var p GlobalPayout
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
func (s *PostgresStore) ListGlobalPayouts(accountID string, limit int) ([]GlobalPayout, error) {
	return s.listGlobalPayouts(`SELECT data FROM global_payout_withdrawals WHERE account_id=$1 AND status<>'quoted' ORDER BY submitted_at DESC LIMIT $2`, accountID, globalPayoutLimit(limit))
}
func (s *PostgresStore) ListGlobalPayoutsToReconcile(now time.Time, limit int) ([]GlobalPayout, error) {
	return s.listGlobalPayouts(`SELECT data FROM global_payout_withdrawals WHERE (status IN ('pending','processing') OR (status='posted' AND submitted_at>$1)) AND checked_at<=$2 AND lease_until<=$3 ORDER BY checked_at LIMIT $4`, now.Add(-90*24*time.Hour), now.Add(-time.Minute), now, globalPayoutLimit(limit))
}
