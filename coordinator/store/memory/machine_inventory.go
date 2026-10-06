package memory

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/internal/store/inventory"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) ObserveMachine(ctx context.Context, o store.MachineObservation) (store.MachineIdentity, error) {
	if err := ctx.Err(); err != nil {
		return store.MachineIdentity{}, err
	}
	if o.SessionID == "" || o.At.IsZero() {
		return store.MachineIdentity{}, errors.New("invalid_machine_observation")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.accountAdmissionLocked(o.AccountID); err != nil {
		return store.MachineIdentity{}, err
	}
	if s.erasedProviderLocked(o.SessionID) {
		return store.MachineIdentity{}, store.ErrErasureConflict
	}
	if s.machineInventory == nil {
		s.machineInventory = inventory.New(s.history)
	}
	return s.machineInventory.ObserveMachine(ctx, o)
}
func (s *MemoryStore) RecordAppAttestEvent(ctx context.Context, e store.AppAttestEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.machineInventory.RecordAppAttestEvent(ctx, e)
}
