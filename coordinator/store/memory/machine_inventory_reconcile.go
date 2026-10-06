package memory

import (
	"context"
	"time"
)

func (s *MemoryStore) ReconcileMachineInventory(ctx context.Context, before time.Time, limit int) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.machineInventory.ReconcileMachineInventory(ctx, before, limit)
}
