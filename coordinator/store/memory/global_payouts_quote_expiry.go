package memory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"
)

// ExpireGlobalPayoutQuote serializes invalidation with the debit transaction.
// A confirmation that already won is returned unchanged and must be reconciled.
func (s *Store) ExpireGlobalPayoutQuote(accountID, id string, now time.Time) (*contracts.GlobalPayout, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok || p.AccountID != accountID {
		return nil, contracts.ErrNotFound
	}
	if p.Status == "quoted" {
		p.ExpiresAt = now
		p.QuoteInvalidated = true
		s.globalPayouts[id] = p
	}
	p = payoutstate.CloneGlobalPayout(p)
	return &p, nil
}
