package memory

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/payoutstate"
)

func (s *Store) RecordGlobalPayoutRejection(id string, attempt int, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return contracts.ErrNotFound
	}
	if err := payoutstate.RecordGlobalRejection(&p, attempt, code); err != nil {
		return err
	}
	s.globalPayouts[id] = p
	return nil
}

func (s *Store) PruneExpiredGlobalPayoutQuotes(now time.Time, limit int) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	expired := []contracts.GlobalPayout{}
	for _, p := range s.globalPayouts {
		if p.Status == "quoted" && !p.ExpiresAt.After(now) {
			expired = append(expired, p)
		}
	}
	sort.Slice(expired, func(i, j int) bool { return expired[i].ExpiresAt.Before(expired[j].ExpiresAt) })
	count := min(len(expired), payoutstate.GlobalQuotePruneLimit(limit))
	for _, p := range expired[:count] {
		delete(s.globalPayouts, p.ID)
	}
	return int64(count), nil
}
