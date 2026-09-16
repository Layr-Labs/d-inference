package memory

import (
	"context"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) UpsertReputation(_ context.Context, providerID string, rep contracts.ReputationRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := rep
	s.reputationRecords[providerID] = &cp
	return nil
}

func (s *Store) GetReputation(_ context.Context, providerID string) (*contracts.ReputationRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rep, ok := s.reputationRecords[providerID]
	if !ok {
		return nil, fmt.Errorf("reputation for provider %q: %w", providerID, contracts.ErrNotFound)
	}
	cp := *rep
	return &cp, nil
}
