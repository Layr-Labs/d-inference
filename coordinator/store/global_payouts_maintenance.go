package store

import (
	"sort"
	"time"
)

func (s *MemoryStore) RecordGlobalPayoutRejection(id string, attempt int, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return ErrNotFound
	}
	if err := recordGlobalRejection(&p, attempt, code); err != nil {
		return err
	}
	s.globalPayouts[id] = p
	return nil
}

func (s *PostgresStore) RecordGlobalPayoutRejection(id string, attempt int, code string) error {
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
	if err = recordGlobalRejection(&p, attempt, code); err != nil {
		return err
	}
	if err = persistGlobalPayout(ctx, tx, p); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Only unconfirmed, expired quotes are disposable. The same row lock used by
// BeginGlobalPayout serializes cleanup with confirmation; locked rows are skipped.
func (s *PostgresStore) PruneExpiredGlobalPayoutQuotes(now time.Time, limit int) (int64, error) {
	ctx, cancel := payoutContext()
	defer cancel()
	result, err := s.pool.Exec(ctx, `WITH expired AS (
 SELECT id FROM global_payout_withdrawals WHERE status='quoted' AND expires_at<=$1
 ORDER BY expires_at LIMIT $2 FOR UPDATE SKIP LOCKED
 ) DELETE FROM global_payout_withdrawals p USING expired e WHERE p.id=e.id AND p.status='quoted'`, now, globalQuotePruneLimit(limit))
	return result.RowsAffected(), err
}

func (s *MemoryStore) PruneExpiredGlobalPayoutQuotes(now time.Time, limit int) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	expired := []GlobalPayout{}
	for _, p := range s.globalPayouts {
		if p.Status == "quoted" && !p.ExpiresAt.After(now) {
			expired = append(expired, p)
		}
	}
	sort.Slice(expired, func(i, j int) bool { return expired[i].ExpiresAt.Before(expired[j].ExpiresAt) })
	count := min(len(expired), globalQuotePruneLimit(limit))
	for _, p := range expired[:count] {
		delete(s.globalPayouts, p.ID)
	}
	return int64(count), nil
}
