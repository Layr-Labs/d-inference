package memory

import (
	"context"
	"errors"
)

func (s *MemoryStore) CanonicalMachineID(ctx context.Context, id string) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.canonicalMachineIDLocked(id)
}

// Caller holds s.mu, including across any admission using the result.
func (s *MemoryStore) canonicalMachineIDLocked(id string) (string, error) {
	if s.machineInventory == nil {
		return "", nil
	}
	for i := 0; i < 100; i++ {
		next := s.machineInventory.Merged[id]
		if next == "" {
			if _, ok := s.machineInventory.Machines[id]; ok {
				return id, nil
			}
			return "", nil
		}
		id = next
	}
	return "", errors.New("machine_merge_cycle")
}
