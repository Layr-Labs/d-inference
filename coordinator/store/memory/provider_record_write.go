package memory

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) UpsertProviderWithReputation(ctx context.Context, p contracts.ProviderRecord, rep contracts.ReputationRecord) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.upsertProviderRecordLocked(p)
	cp := rep
	s.reputationRecords[p.ID] = &cp
	return nil
}
