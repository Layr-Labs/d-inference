package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// ExpireGlobalPayoutQuote serializes invalidation with the debit transaction.
// A confirmation that already won is returned unchanged and must be reconciled.
func (s *MemoryStore) ExpireGlobalPayoutQuote(accountID, id string, now time.Time) (*store.GlobalPayout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok || p.AccountID != accountID {
		return nil, store.ErrNotFound
	}
	if p.Status == "quoted" {
		p.ExpiresAt = now
		p.QuoteInvalidated = true
		s.globalPayouts[id] = p
	}
	p = cloneGlobalPayout(p)
	return &p, nil
}
