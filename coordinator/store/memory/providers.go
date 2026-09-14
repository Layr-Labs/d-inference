package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) UpsertProvider(_ context.Context, p contracts.ProviderRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.upsertProviderRecordLocked(p)
	return nil
}

func (s *Store) upsertProviderRecordLocked(p contracts.ProviderRecord) {
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
}

func (s *Store) GetProviderRecord(_ context.Context, id string) (*contracts.ProviderRecord, error) {
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

func (s *Store) GetProviderBySerial(_ context.Context, serial string) (*contracts.ProviderRecord, error) {
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

func (s *Store) GetMDAChainBySerial(_ context.Context, serial string) (json.RawMessage, error) {
	if serial == "" {
		return nil, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Scan all records (not just the serial-indexed latest) so a newer empty-chain
	// row cannot shadow a chain-bearing one from a prior connection. Pick the most
	// recently seen non-empty chain.
	var best *contracts.ProviderRecord
	for _, p := range s.providerRecords {
		if p.SerialNumber != serial || len(p.MDACertChain) == 0 {
			continue
		}
		if best == nil || p.LastSeen.After(best.LastSeen) {
			best = p
		}
	}
	if best == nil {
		return nil, nil
	}
	out := make(json.RawMessage, len(best.MDACertChain))
	copy(out, best.MDACertChain)
	return out, nil
}

func (s *Store) ListProviderRecords(_ context.Context) ([]contracts.ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]contracts.ProviderRecord, 0, len(s.providerRecords))
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

func (s *Store) ListProvidersByAccount(_ context.Context, accountID string) ([]contracts.ProviderRecord, error) {
	if accountID == "" {
		return []contracts.ProviderRecord{}, nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]contracts.ProviderRecord, 0)
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

func (s *Store) DeleteProvidersBySerial(_ context.Context, ownerAccountID, serialOrID string) (int, error) {
	if ownerAccountID == "" || serialOrID == "" {
		return 0, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Iterate the full record map (not just the serial index) so historical
	// duplicate rows sharing a serial are all caught. Match by serial OR id, but
	// only delete rows owned by the caller — rows owned by another account are
	// skipped and not counted, leaving the caller to decide 403 vs 404.
	var matched []string
	for id, rec := range s.providerRecords {
		if rec.AccountID != ownerAccountID {
			continue
		}
		if (rec.SerialNumber == serialOrID && rec.SerialNumber != "") || rec.ID == serialOrID {
			matched = append(matched, id)
		}
	}

	for _, id := range matched {
		rec := s.providerRecords[id]
		if rec.SerialNumber != "" && s.serialToProviderID[rec.SerialNumber] == id {
			delete(s.serialToProviderID, rec.SerialNumber)
		}
		delete(s.providerRecords, id)
		delete(s.reputationRecords, id)
		// usage, provider_earnings and provider_sessions are intentionally
		// preserved — they hold money/uptime history.
	}
	return len(matched), nil
}

func (s *Store) UpdateProviderLastSeen(_ context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.providerRecords[id]
	if !ok {
		return fmt.Errorf("provider %q not found", id)
	}
	p.LastSeen = time.Now()
	return nil
}

func (s *Store) UpdateProviderTrust(_ context.Context, id string, trustLevel string, attested bool, attestationResult json.RawMessage) error {
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

func (s *Store) UpdateProviderChallenge(_ context.Context, id string, lastVerified time.Time, failedCount int) error {
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

func (s *Store) UpdateProviderRuntime(_ context.Context, id string, verified bool, pythonHash, runtimeHash string) error {
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
