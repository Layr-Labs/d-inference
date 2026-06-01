package store

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"
)

// --- Provider Fleet Persistence ---

func (s *MemoryStore) UpsertProvider(_ context.Context, p ProviderRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Update serial index
	if p.SerialNumber != "" {
		// Remove old serial mapping if exists
		if old, ok := s.providerRecords[p.ID]; ok && old.SerialNumber != "" && old.SerialNumber != p.SerialNumber {
			delete(s.serialToProviderID, old.SerialNumber)
		}
		s.serialToProviderID[p.SerialNumber] = p.ID
	}

	cp := p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	s.providerRecords[p.ID] = &cp
	return nil
}

func (s *MemoryStore) GetProviderRecord(_ context.Context, id string) (*ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return nil, fmt.Errorf("provider %q not found", id)
	}
	cp := *p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func (s *MemoryStore) GetProviderBySerial(_ context.Context, serial string) (*ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	id, ok := s.serialToProviderID[serial]
	if !ok {
		return nil, fmt.Errorf("provider with serial %q not found", serial)
	}
	p, ok := s.providerRecords[id]
	if !ok {
		return nil, fmt.Errorf("provider %q not found (stale serial index)", id)
	}
	cp := *p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func (s *MemoryStore) ListProviderRecords(_ context.Context) ([]ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ProviderRecord, 0, len(s.providerRecords))
	for _, p := range s.providerRecords {
		cp := *p
		if p.Location != nil {
			loc := *p.Location
			cp.Location = &loc
		}
		records = append(records, cp)
	}
	return records, nil
}

func (s *MemoryStore) ListProvidersByAccount(_ context.Context, accountID string) ([]ProviderRecord, error) {
	if accountID == "" {
		return []ProviderRecord{}, nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]ProviderRecord, 0)
	for _, p := range s.providerRecords {
		if p.AccountID == accountID {
			cp := *p
			if p.Location != nil {
				loc := *p.Location
				cp.Location = &loc
			}
			records = append(records, cp)
		}
	}
	sort.Slice(records, func(i, j int) bool {
		return records[i].LastSeen.After(records[j].LastSeen)
	})
	return records, nil
}

func (s *MemoryStore) UpdateProviderLastSeen(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.LastSeen = time.Now()
	return nil
}

func (s *MemoryStore) UpdateProviderTrust(_ context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.TrustLevel = trustLevel
	p.Attested = attested
	p.AttestationResult = attestationResult
	return nil
}

func (s *MemoryStore) UpdateProviderChallenge(_ context.Context, id string, lastVerified time.Time, failedCount int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.LastChallengeVerified = &lastVerified
	p.FailedChallenges = failedCount
	return nil
}

func (s *MemoryStore) UpdateProviderRuntime(_ context.Context, id string, verified bool, pythonHash, runtimeHash string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.RuntimeVerified = verified
	p.PythonHash = pythonHash
	p.RuntimeHash = runtimeHash
	return nil
}

// --- Provider Reputation Persistence ---

func (s *MemoryStore) UpsertReputation(_ context.Context, providerID string, rep ReputationRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := rep
	s.reputationRecords[providerID] = &cp
	return nil
}

func (s *MemoryStore) GetReputation(_ context.Context, providerID string) (*ReputationRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rep, ok := s.reputationRecords[providerID]
	if !ok {
		return nil, fmt.Errorf("reputation for provider %q not found", providerID)
	}
	cp := *rep
	return &cp, nil
}
