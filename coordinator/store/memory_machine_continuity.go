package store

import (
	"context"
	"slices"
)

func (s *MemoryStore) ResolveMachineContinuity(ctx context.Context, sessionID, account, key string, excluded []string) (MachineContinuity, error) {
	var result MachineContinuity
	if err := ctx.Err(); err != nil {
		return result, err
	}
	if sessionID == "" || account == "" || key == "" {
		return result, ErrMachineContinuityUnverified
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	m := s.machineInventory
	credential, exists := s.appAttestShadowKeys[key]
	if m == nil || !exists || credential.AccountID != account || s.appAttestRevocations[key] {
		return result, ErrMachineContinuityUnverified
	}
	session, ok := m.sessions[sessionID]
	id := m.sessionMachines[sessionID]
	if !ok || session.AccountID != account || session.Disconnected || id == "" || m.aliases[appAttestMachineAlias(account, key)] != id {
		return result, ErrMachineContinuityUnverified
	}
	result.Machine, ok = m.machines[id]
	if !ok || result.Machine.Assurance == "provisional" {
		return MachineContinuity{}, ErrMachineContinuityUnverified
	}
	for priorID, priorMachine := range m.sessionMachines {
		if priorMachine != id || priorID == sessionID || slices.Contains(excluded, priorID) || m.sessions[priorID].AccountID != account {
			continue
		}
		p := s.providerRecords[priorID]
		if p != nil && p.AccountID == account && newerProviderRecord(p, result.Previous) {
			result.Previous = p
		}
	}
	result.Previous = cloneMachineHistory(result.Previous)
	return result, nil
}
