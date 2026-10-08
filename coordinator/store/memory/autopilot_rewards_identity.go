package memory

import (
	"context"
	"errors"
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/store/memoryhistory"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

type autopilotRewardMachine struct {
	id        string
	accountID string
	aliases   map[string]bool
	sessions  map[string]bool
	firstSeen time.Time
}

// Inventory identity, enrollment and money share s.mu, including across merges.
func (s *MemoryStore) autopilotRewardMachineLocked(id string) (autopilotRewardMachine, error) {
	canonical, err := s.canonicalMachineIDLocked(id)
	if err != nil {
		return autopilotRewardMachine{}, err
	}
	m := s.machineInventory
	if canonical == "" || m.Machines[canonical].Assurance == "provisional" {
		return autopilotRewardMachine{}, earningsfloor.ErrIdentity
	}
	machine := autopilotRewardMachine{id: canonical, aliases: map[string]bool{canonical: true}, sessions: make(map[string]bool)}
	for ancestor := range m.Merged {
		resolved, err := s.canonicalMachineIDLocked(ancestor)
		if err != nil {
			return autopilotRewardMachine{}, err
		}
		if resolved == canonical {
			machine.aliases[ancestor] = true
		}
	}
	for session, member := range m.SessionMachines {
		if !machine.aliases[member] {
			continue
		}
		machine.sessions[session] = true
		account := m.Sessions[session].AccountID
		if account != "" {
			if machine.accountID != "" && machine.accountID != account {
				return autopilotRewardMachine{}, earningsfloor.ErrIdentity
			}
			machine.accountID = account
		}
		first := m.SessionFirstSeen[session]
		if first.IsZero() {
			return autopilotRewardMachine{}, earningsfloor.ErrHistory
		}
		if machine.firstSeen.IsZero() || first.Before(machine.firstSeen) {
			machine.firstSeen = first
		}
	}
	if machine.accountID == "" {
		return autopilotRewardMachine{}, earningsfloor.ErrIdentity
	}
	for _, session := range s.history.ProviderSessions {
		if machine.sessions[session.SessionID] && session.AccountID != "" && session.AccountID != machine.accountID {
			return autopilotRewardMachine{}, earningsfloor.ErrIdentity
		}
	}
	for session := range machine.sessions {
		if owner := s.autopilotRewardConsents[session].accountID; owner != "" && owner != machine.accountID {
			return autopilotRewardMachine{}, earningsfloor.ErrIdentity
		}
	}
	if s.erasedAccounts[machine.accountID] {
		return autopilotRewardMachine{}, store.ErrErasureConflict
	}
	if err := s.accountAdmissionLocked(machine.accountID); err != nil {
		return autopilotRewardMachine{}, err
	}
	for ancestor := range machine.aliases {
		if enrollment, ok := s.autopilotRewardEnrollments[ancestor]; ok && enrollment.AccountID != machine.accountID {
			return autopilotRewardMachine{}, earningsfloor.ErrIdentity
		}
	}
	return machine, nil
}

// Session attribution wins even when an unrelated endpoint reuses its key.
// A key-only legacy row may use only an unambiguous, same-owner association.
func (s *MemoryStore) autopilotRewardEarningMachineLocked(source memoryhistory.EarningSource, target string) (string, error) {
	m := s.machineInventory
	if m == nil {
		return "", nil
	}
	if id, known := m.SessionMachines[source.ProviderID]; known {
		if m.Sessions[source.ProviderID].AccountID != source.AccountID {
			return "", nil
		}
		for _, session := range s.history.ProviderSessions {
			if session.SessionID == source.ProviderID && session.AccountID != "" && session.AccountID != source.AccountID {
				return "", nil
			}
		}
		canonical, err := s.canonicalMachineIDLocked(id)
		if err != nil {
			return "", err
		}
		if canonical == "" || m.Machines[canonical].Assurance == "provisional" {
			return "", nil
		}
		return canonical, nil
	}
	if source.ProviderKey == "" {
		return "", nil
	}
	if s.history.ProviderKeysPruned[source.AccountID] {
		return "", earningsfloor.ErrHistory
	}
	matches := make(map[string]bool)
	ambiguous := false
	for _, session := range s.history.ProviderSessions {
		if session.AccountID != source.AccountID || session.ProviderKey != source.ProviderKey {
			continue
		}
		id, known := m.SessionMachines[session.SessionID]
		if !known {
			continue
		}
		canonical, err := s.canonicalMachineIDLocked(id)
		if err != nil {
			return "", err
		}
		if canonical == "" || m.Sessions[session.SessionID].AccountID != source.AccountID || m.Machines[canonical].Assurance == "provisional" {
			ambiguous = true
			continue
		}
		matches[canonical] = true
	}
	if matches[target] && (len(matches) > 1 || ambiguous) {
		return "", earningsfloor.ErrIdentity
	}
	if len(matches) == 1 {
		for id := range matches {
			return id, nil
		}
	}
	return "", nil
}

func (s *MemoryStore) autopilotRewardInferenceLocked(ctx context.Context, machine autopilotRewardMachine, start, end time.Time) (int64, error) {
	sources := make(map[memoryhistory.EarningSource]string)
	belongs := func(source memoryhistory.EarningSource) (bool, error) {
		id, known := sources[source]
		if !known {
			var err error
			id, err = s.autopilotRewardEarningMachineLocked(source, machine.id)
			if err != nil {
				return false, err
			}
			sources[source] = id
		}
		return id == machine.id, nil
	}
	for source, through := range s.history.EarningsPrunedThrough {
		if source.AccountID != machine.accountID || through.Before(start) {
			continue
		}
		match, err := belongs(source)
		if err != nil {
			return 0, err
		}
		if match {
			return 0, earningsfloor.ErrHistory
		}
	}
	var total int64
	for _, earning := range s.history.ProviderEarnings {
		if earning.AccountID != machine.accountID || earning.Model == "base_reward" || earning.CreatedAt.Before(start) || !earning.CreatedAt.Before(end) {
			continue
		}
		match, err := belongs(memoryhistory.EarningSource{AccountID: earning.AccountID, ProviderID: earning.ProviderID, ProviderKey: earning.ProviderKey})
		if err != nil {
			return 0, err
		}
		if !match {
			continue
		}
		if earning.AmountMicroUSD < 0 || earning.AmountMicroUSD > math.MaxInt64-total {
			return 0, errors.New("invalid or overflowing autopilot inference earnings")
		}
		total += earning.AmountMicroUSD
	}
	return total, ctx.Err()
}
