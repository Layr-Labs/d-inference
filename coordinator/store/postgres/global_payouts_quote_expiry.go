package postgres

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *PostgresStore) ExpireGlobalPayoutQuote(accountID, id string, now time.Time) (*store.GlobalPayout, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	var p store.GlobalPayout
	if err = readPayoutJSON(tx.QueryRow(ctx, `SELECT data FROM global_payout_withdrawals WHERE id=$1 AND account_id=$2 FOR UPDATE`, id, accountID), &p); err != nil {
		return nil, err
	}
	if p.Status == "quoted" {
		p.ExpiresAt = now
		p.QuoteInvalidated = true
		if err = persistGlobalPayout(ctx, tx, p); err != nil {
			return nil, err
		}
	}
	return &p, tx.Commit(ctx)
}
