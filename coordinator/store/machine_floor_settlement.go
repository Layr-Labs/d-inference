package store

import (
	"context"
	"errors"
)

// SettleMachineFloorDraw resolves verified merges while holding the same lock
// as inventory writes. A late identity merge cannot bypass an earlier draw
// under a previous machine ID or any original session encryption key.
func (s *MemoryStore) SettleMachineFloorDraw(ctx context.Context, machine string, draw *ProviderFloorDraw) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if machine == "" || draw == nil || draw.AccountID == "" || draw.EpochID == "" {
		return false, errors.New("invalid_machine_floor_draw")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.settleMachineFloorDrawLocked(machine, draw)
}

func (s *MemoryStore) settleMachineFloorDrawLocked(machine string, draw *ProviderFloorDraw) (bool, error) {
	m := s.machineInventory
	if m == nil {
		return false, ErrMachineContinuityUnverified
	}
	canonical := machine
	for i := 0; i < 100 && m.merged[canonical] != ""; i++ {
		canonical = m.merged[canonical]
	}
	if identity, ok := m.machines[canonical]; !ok || identity.Assurance == "provisional" {
		return false, ErrMachineContinuityUnverified
	}
	previousKeys := map[string]bool{MachineFloorKey(canonical): true}
	for source := range m.merged {
		next := source
		for i := 0; i < 100 && next != ""; i++ {
			if next == canonical {
				previousKeys[MachineFloorKey(source)] = true
				break
			}
			next = m.merged[next]
		}
	}
	accountKnown := false
	for sessionID, id := range m.sessionMachines {
		if id != canonical {
			continue
		}
		if m.sessions[sessionID].AccountID == draw.AccountID {
			accountKnown = true
		}
	}
	for _, session := range s.providerSessions {
		if m.sessionMachines[session.SessionID] == canonical && session.ProviderKey != "" {
			previousKeys[session.ProviderKey] = true
		}
	}
	if !accountKnown {
		return false, ErrMachineContinuityUnverified
	}
	for key := range previousKeys {
		if _, settled := s.floorDrawKeys[floorDrawKey(key, draw.EpochID)]; settled {
			return false, nil
		}
	}
	copy := *draw
	copy.ProviderKey = MachineFloorKey(canonical)
	return s.settleProviderFloorDrawLocked(&copy)
}

// Even a candidate built before inventory binding appeared must resolve that
// binding at the money handoff. Raw-first and canonical-first settlement share
// one merge barrier and therefore cannot create two floors for the same epoch.
func (s *MemoryStore) SettleProviderFloorDrawForSession(ctx context.Context, sessionID string, draw *ProviderFloorDraw) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if sessionID == "" || draw == nil || draw.AccountID == "" || draw.ProviderKey == "" || draw.EpochID == "" {
		return false, errors.New("invalid_machine_floor_draw")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if m := s.machineInventory; m != nil {
		if o, exists := m.sessions[sessionID]; exists {
			if o.AccountID != "" && o.AccountID != draw.AccountID {
				return false, ErrMachineContinuityUnverified
			}
			id := m.sessionMachines[sessionID]
			if identity, known := m.machines[id]; known && identity.Assurance != "provisional" {
				return s.settleMachineFloorDrawLocked(id, draw)
			}
		}
	}
	return s.settleProviderFloorDrawLocked(draw)
}
