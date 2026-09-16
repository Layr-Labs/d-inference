package memory

import (
	"context"
	"errors"
)

func (s *Store) CanonicalMachineID(ctx context.Context, id string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.machineInventory == nil {
		return "", nil
	}
	for i := 0; i < 100; i++ {
		next := s.machineInventory.merged[id]
		if next == "" {
			if _, ok := s.machineInventory.machines[id]; ok {
				return id, nil
			}
			return "", nil
		}
		id = next
	}
	return "", errors.New("machine_merge_cycle")
}
