package memory

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
)

var _ store.MachineAutopilotStore = (*MemoryStore)(nil)

func (s *MemoryStore) ListMachineAutopilotSettings(ctx context.Context, after string, limit int) ([]store.MachineAutopilotSetting, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.machineInventory.ListMachineAutopilotSettings(ctx, after, limit)
}

func (s *MemoryStore) LiveMachineAutopilotSettings(ctx context.Context) ([]store.MachineAutopilotSetting, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.machineInventory.LiveMachineAutopilotSettings(ctx)
}

func (s *MemoryStore) SetMachineAutopilotDesiredMode(ctx context.Context, machineID string, mode store.MachineAutopilotMode) (store.MachineAutopilotSetting, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.machineInventory.SetMachineAutopilotDesiredMode(ctx, machineID, mode)
}
