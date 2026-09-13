package store

import "time"

// ExpireGlobalPayoutQuote serializes invalidation with the debit transaction.
// A confirmation that already won is returned unchanged and must be reconciled.
func (s *MemoryStore) ExpireGlobalPayoutQuote(accountID, id string, now time.Time) (*GlobalPayout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok || p.AccountID != accountID {
		return nil, ErrNotFound
	}
	if p.Status == "quoted" {
		p.ExpiresAt = now
		p.QuoteInvalidated = true
		s.globalPayouts[id] = p
	}
	p = cloneGlobalPayout(p)
	return &p, nil
}

func (s *PostgresStore) ExpireGlobalPayoutQuote(accountID, id string, now time.Time) (*GlobalPayout, error) {
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
	if p.Status == "quoted" {
		p.ExpiresAt = now
		p.QuoteInvalidated = true
		if err = persistGlobalPayout(ctx, tx, p); err != nil {
			return nil, err
		}
	}
	return &p, tx.Commit(ctx)
}
