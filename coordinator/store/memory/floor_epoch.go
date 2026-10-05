package memory

import "context"

func (s *MemoryStore) WithEpochSettlementLock(ctx context.Context, epoch string, fn func() error) error {
	return s.epochLocks.WithEpochSettlementLock(ctx, epoch, fn)
}
