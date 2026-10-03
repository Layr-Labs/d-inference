package memory

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

func (s *MemoryStore) RecordGlobalPayoutRejection(id string, attempt int, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return store.ErrNotFound
	}
	if err := shared.RecordGlobalRejection(&p, attempt, code); err != nil {
		return err
	}
	s.globalPayouts[id] = p
	return nil
}

func (s *MemoryStore) PruneExpiredGlobalPayoutQuotes(now time.Time, limit int) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	expired := []store.GlobalPayout{}
	for _, p := range s.globalPayouts {
		if p.Status == "quoted" && !p.ExpiresAt.After(now) {
			expired = append(expired, p)
		}
	}
	sort.Slice(expired, func(i, j int) bool { return expired[i].ExpiresAt.Before(expired[j].ExpiresAt) })
	count := min(len(expired), shared.GlobalQuotePruneLimit(limit))
	for _, p := range expired[:count] {
		delete(s.globalPayouts, p.ID)
	}
	return int64(count), nil
}
