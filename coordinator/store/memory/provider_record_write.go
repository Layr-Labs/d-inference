package memory

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) UpsertProviderWithReputation(ctx context.Context, p store.ProviderRecord, rep store.ReputationRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.accountAdmissionLocked(p.AccountID); err != nil {
		return err
	}
	s.upsertProviderRecordLocked(p)
	cp := rep
	s.reputationRecords[p.ID] = &cp
	return nil
}
