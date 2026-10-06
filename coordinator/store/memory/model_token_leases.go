package memory

import "time"

func (s *MemoryStore) RenewModelTokenReservations(ids []string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, id := range ids {
		if r, ok := s.modelTokenReservations[id]; ok && r.State == "reserved" {
			r.TouchedAt = now
			s.modelTokenReservations[id] = r
		}
	}
	return nil
}

func (s *MemoryStore) ReleaseStaleModelTokenReservations(before time.Time) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for id := range s.modelTokenReservations {
		if count >= 100 {
			return count, nil
		}
		released, err := s.releaseModelTokenLocked(id, before)
		if err != nil {
			return count, err
		}
		if released {
			count++
		}
	}
	return count, nil
}
