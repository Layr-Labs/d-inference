package memory

import (
	"bytes"
	"context"
	"slices"

	"github.com/eigeninference/d-inference/coordinator/internal/store/shared"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func cloneMachineHistory(p *store.ProviderRecord) *store.ProviderRecord {
	if p == nil {
		return nil
	}
	cp := *p
	cp.Hardware = bytes.Clone(p.Hardware)
	cp.Models = bytes.Clone(p.Models)
	cp.AttestationResult = bytes.Clone(p.AttestationResult)
	cp.MDACertChain = bytes.Clone(p.MDACertChain)
	cp.LifetimeStats = bytes.Clone(p.LifetimeStats)
	cp.LastSessionStats = bytes.Clone(p.LastSessionStats)
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	if p.LastChallengeVerified != nil {
		at := *p.LastChallengeVerified
		cp.LastChallengeVerified = &at
	}
	return &cp
}

var _ store.MachineOperationalStore = (*MemoryStore)(nil)

var _ store.MachineContinuityRecoveryStore = (*MemoryStore)(nil)

func (s *MemoryStore) ResolveMachineContinuity(ctx context.Context, sessionID, account, key string, excluded []string) (store.MachineContinuity, error) {
	var result store.MachineContinuity
	if err := ctx.Err(); err != nil {
		return result, err
	}
	if sessionID == "" || account == "" || key == "" {
		return result, store.ErrMachineContinuityUnverified
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	m := s.machineInventory
	credential, exists := s.appAttestShadowKeys[key]
	if m == nil || !exists || credential.AccountID != account || s.appAttestRevocations[key] {
		return result, store.ErrMachineContinuityUnverified
	}
	session, ok := m.Sessions[sessionID]
	id := m.SessionMachines[sessionID]
	if !ok || session.AccountID != account || session.Disconnected || id == "" || m.Aliases[shared.AppAttestMachineAlias(account, key)] != id {
		return result, store.ErrMachineContinuityUnverified
	}
	result.Machine, ok = m.Machines[id]
	if !ok || result.Machine.Assurance == "provisional" {
		return store.MachineContinuity{}, store.ErrMachineContinuityUnverified
	}
	for priorID, priorMachine := range m.SessionMachines {
		if priorMachine != id || priorID == sessionID || slices.Contains(excluded, priorID) || m.Sessions[priorID].AccountID != account {
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
