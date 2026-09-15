package store

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
)

type memoryMachineInventory struct {
	merged          map[string]string
	machines        map[string]MachineIdentity
	aliases         map[machineAlias]string
	sessions        map[string]MachineObservation
	sessionMachines map[string]string
	events          []AppAttestEvent
}

func (s *MemoryStore) ObserveMachine(ctx context.Context, o MachineObservation) (MachineIdentity, error) {
	if err := ctx.Err(); err != nil {
		return MachineIdentity{}, err
	}
	if o.SessionID == "" || o.At.IsZero() {
		return MachineIdentity{}, errors.New("invalid_machine_observation")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.machineInventory == nil {
		s.machineInventory = &memoryMachineInventory{machines: map[string]MachineIdentity{}, aliases: map[machineAlias]string{}, sessions: map[string]MachineObservation{}, sessionMachines: map[string]string{}}
	}
	m := s.machineInventory
	if old, ok := m.sessions[o.SessionID]; ok {
		if o.Source != "historical_registration" && old.AccountID != o.AccountID {
			return MachineIdentity{}, errors.New("machine_session_owner_conflict")
		}
		if o.Source == "historical_registration" || inventoryObservationSuperseded(old.At, old.Disconnected, old.DisconnectReason, o) {
			return m.machines[m.sessionMachines[o.SessionID]], nil
		}
	}
	if o.Disconnected && o.DisconnectReason == "" {
		o.DisconnectReason = "observed_disconnect"
	}
	var candidates []string
	for _, a := range o.aliases() {
		if id := m.aliases[a]; id != "" {
			candidates = append(candidates, id)
		}
	}
	if id := m.sessionMachines[o.SessionID]; id != "" {
		candidates = append(candidates, id)
	}
	id := uuid.NewString()
	if len(candidates) > 0 {
		id = candidates[0]
	}
	identity := MachineIdentity{ID: id, Assurance: strongerAssurance(m.machines[id].Assurance, o.assurance())}
	for _, old := range candidates {
		if old == id {
			continue
		}
		for a, v := range m.aliases {
			if v == old {
				m.aliases[a] = id
			}
		}
		for session, v := range m.sessionMachines {
			if v == old {
				m.sessionMachines[session] = id
			}
		}
		if m.merged == nil {
			m.merged = map[string]string{}
		}
		m.merged[old] = id
		delete(m.machines, old)
	}
	m.machines[id] = identity
	for _, a := range o.aliases() {
		m.aliases[a] = id
	}
	m.sessionMachines[o.SessionID] = id
	m.sessions[o.SessionID] = o
	return identity, nil
}

func (s *MemoryStore) RecordAppAttestEvent(ctx context.Context, e AppAttestEvent) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.machineInventory == nil {
		return errors.New("machine_inventory_uninitialized")
	}
	e.Fields = append(json.RawMessage(nil), e.Fields...)
	s.machineInventory.events = append(s.machineInventory.events, e)
	return nil
}
