package memory

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

func (s *MemoryStore) StartUnsentGlobalPayout(id string, leaseUntil time.Time, request, fees json.RawMessage, destinationAmount int64, expiresAt, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return store.ErrNotFound
	}
	if err := shared.StartUnsentGlobalPayout(&p, leaseUntil, request, fees, destinationAmount, expiresAt, now); err != nil {
		return err
	}
	s.globalPayouts[id] = p
	return nil
}

func (s *MemoryStore) StartGlobalPayoutDispatch(id string, leaseUntil, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	p, ok := s.globalPayouts[id]
	if !ok {
		return store.ErrNotFound
	}
	if err := shared.StartGlobalPayoutDispatch(&p, leaseUntil, now); err != nil {
		return err
	}
	s.globalPayouts[id] = p
	return nil
}
