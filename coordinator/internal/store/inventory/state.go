package inventory

import (
	"context"
	"encoding/json"
	"errors"

	memoryhistory "github.com/eigeninference/d-inference/coordinator/internal/store/memoryhistory"
	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// State owns machine identity and observation tables. The enclosing memory
// store holds its transaction mutex across inventory and history operations.
type State struct {
	History         *memoryhistory.State
	Merged          map[string]string
	Machines        map[string]store.MachineIdentity
	Aliases         map[store.MachineAlias]string
	Sessions        map[string]store.MachineObservation
	SessionMachines map[string]string
	Events          []store.AppAttestEvent
}

func (s *State) ObserveMachine(ctx context.Context, o store.MachineObservation) (store.MachineIdentity, error) {
	if err := ctx.Err(); err != nil {
		return store.MachineIdentity{}, err
	}
	if o.SessionID == "" || o.At.IsZero() {
		return store.MachineIdentity{}, errors.New("invalid_machine_observation")
	}

	m := s
	if old, ok := m.Sessions[o.SessionID]; ok {
		if o.Source != "historical_registration" && old.AccountID != o.AccountID {
			return store.MachineIdentity{}, errors.New("machine_session_owner_conflict")
		}
		if o.Source == "historical_registration" || shared.InventoryObservationSuperseded(old.At, old.Disconnected, old.DisconnectReason, o) {
			return m.Machines[m.SessionMachines[o.SessionID]], nil
		}
	}
	if o.Disconnected && o.DisconnectReason == "" {
		o.DisconnectReason = "observed_disconnect"
	}
	var candidates []string
	for _, a := range o.Aliases() {
		if id := m.Aliases[a]; id != "" {
			candidates = append(candidates, id)
		}
	}
	if id := m.SessionMachines[o.SessionID]; id != "" {
		candidates = append(candidates, id)
	}
	id := uuid.NewString()
	if len(candidates) > 0 {
		id = candidates[0]
	}
	identity := store.MachineIdentity{ID: id, Assurance: shared.StrongerAssurance(m.Machines[id].Assurance, o.Assurance())}
	for _, old := range candidates {
		if old == id {
			continue
		}
		for a, v := range m.Aliases {
			if v == old {
				m.Aliases[a] = id
			}
		}
		for session, v := range m.SessionMachines {
			if v == old {
				m.SessionMachines[session] = id
			}
		}
		if m.Merged == nil {
			m.Merged = map[string]string{}
		}
		m.Merged[old] = id
		delete(m.Machines, old)
	}
	m.Machines[id] = identity
	for _, a := range o.Aliases() {
		m.Aliases[a] = id
	}
	m.SessionMachines[o.SessionID] = id
	m.Sessions[o.SessionID] = o
	return identity, nil
}

func (s *State) RecordAppAttestEvent(ctx context.Context, e store.AppAttestEvent) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	if s == nil {
		return errors.New("machine_inventory_uninitialized")
	}
	e.Fields = append(json.RawMessage(nil), e.Fields...)
	s.Events = append(s.Events, e)
	return nil
}

func New(history *memoryhistory.State) *State {
	return &State{History: history, Machines: map[string]store.MachineIdentity{}, Aliases: map[store.MachineAlias]string{}, Sessions: map[string]store.MachineObservation{}, SessionMachines: map[string]string{}}
}
