package memory

import (
	"context"
	"errors"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// SettleMachineFloorDraw resolves verified merges while holding the same lock
// as inventory writes. A late identity merge cannot bypass an earlier draw
// under a previous machine ID or any original session encryption key.
func (s *MemoryStore) SettleMachineFloorDraw(ctx context.Context, machine string, draw *store.ProviderFloorDraw) (bool, error) {
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

func (s *MemoryStore) settleMachineFloorDrawLocked(machine string, draw *store.ProviderFloorDraw) (bool, error) {
	resolved, already, err := s.resolveMachineFloorDrawLocked(machine, draw)
	if err != nil || already {
		return false, err
	}
	return s.settleProviderFloorDrawLocked(&resolved)
}

func (s *MemoryStore) resolveMachineFloorDrawLocked(machine string, draw *store.ProviderFloorDraw) (store.ProviderFloorDraw, bool, error) {
	m := s.machineInventory
	if m == nil {
		return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
	}
	canonical := machine
	for i := 0; i < 100 && m.Merged[canonical] != ""; i++ {
		canonical = m.Merged[canonical]
	}
	if identity, ok := m.Machines[canonical]; !ok || identity.Assurance == "provisional" {
		return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
	}
	previousKeys := map[string]bool{store.MachineFloorKey(canonical): true}
	for source := range m.Merged {
		next := source
		for i := 0; i < 100 && next != ""; i++ {
			if next == canonical {
				previousKeys[store.MachineFloorKey(source)] = true
				break
			}
			next = m.Merged[next]
		}
	}
	accountKnown := false
	for sessionID, id := range m.SessionMachines {
		if id != canonical {
			continue
		}
		if m.Sessions[sessionID].AccountID == draw.AccountID {
			accountKnown = true
		}
	}
	for _, session := range s.history.ProviderSessions {
		if m.SessionMachines[session.SessionID] == canonical && session.ProviderKey != "" {
			previousKeys[session.ProviderKey] = true
		}
	}
	if !accountKnown {
		return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
	}
	for key := range previousKeys {
		if _, settled := s.floorDrawKeys[floorDrawKey(key, draw.EpochID)]; settled {
			copy := *draw
			copy.ProviderKey = store.MachineFloorKey(canonical)
			return copy, true, nil
		}
	}
	copy := *draw
	copy.ProviderKey = store.MachineFloorKey(canonical)
	return copy, false, nil
}

// resolveSessionFloorDrawLocked resolves a session's draw at the money
// handoff: even a candidate built before inventory binding appeared must
// resolve that binding, so raw-first and canonical-first settlement share one
// merge barrier and cannot create two floors for the same epoch.
func (s *MemoryStore) resolveSessionFloorDrawLocked(sessionID string, draw *store.ProviderFloorDraw) (store.ProviderFloorDraw, bool, error) {
	if m := s.machineInventory; m != nil {
		if o, exists := m.Sessions[sessionID]; exists {
			if o.AccountID != "" && o.AccountID != draw.AccountID {
				return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
			}
			id := m.SessionMachines[sessionID]
			if identity, known := m.Machines[id]; known && identity.Assurance != "provisional" {
				return s.resolveMachineFloorDrawLocked(id, draw)
			}
		}
		// A reconnect can be publicly authorized before its first inventory
		// write lands. The live caller already proved this endpoint key; reuse
		// only its same-account durable association, never a claimed serial.
		machine := ""
		for _, prior := range s.history.ProviderSessions {
			if prior.ProviderKey != draw.ProviderKey || prior.AccountID != draw.AccountID || m.Sessions[prior.SessionID].AccountID != draw.AccountID {
				continue
			}
			id := m.SessionMachines[prior.SessionID]
			identity, known := m.Machines[id]
			if !known || identity.Assurance == "provisional" {
				continue
			}
			if machine != "" && machine != id {
				return store.ProviderFloorDraw{}, false, store.ErrMachineContinuityUnverified
			}
			machine = id
		}
		if machine != "" {
			return s.resolveMachineFloorDrawLocked(machine, draw)
		}
	}
	_, already := s.floorDrawKeys[floorDrawKey(draw.ProviderKey, draw.EpochID)]
	return *draw, already, nil
}
