package postgres

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"
	"github.com/jackc/pgx/v5"
)

func (s *Store) RecordGlobalPayoutRejection(id string, attempt int, code string) error {
	ctx, cancel := payoutContext()
	defer cancel()
	_, err := s.mutateGlobalPayout(ctx, id, func(_ pgx.Tx, p *contracts.GlobalPayout) (bool, error) {
		return true, payoutstate.RecordGlobalRejection(p, attempt, code)
	})
	return err
}

// Only unconfirmed, expired quotes are disposable. The same row lock used by
// BeginGlobalPayout serializes cleanup with confirmation; locked rows are skipped.
func (s *Store) PruneExpiredGlobalPayoutQuotes(now time.Time, limit int) (int64, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	result, err := s.pool.Exec(ctx, `WITH expired AS (
 SELECT id FROM global_payout_withdrawals WHERE status='quoted' AND expires_at<=$1
 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED
 ) DELETE FROM global_payout_withdrawals p USING expired e WHERE p.id=e.id AND p.status='quoted'`, now, payoutstate.GlobalQuotePruneLimit(limit))
	return result.RowsAffected(), err
}
