package memory

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) UpsertProvider(_ context.Context, p store.ProviderRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.accountAdmissionLocked(p.AccountID); err != nil {
		return err
	}

	s.upsertProviderRecordLocked(p)
	return nil
}

func (s *MemoryStore) upsertProviderRecordLocked(p store.ProviderRecord) {
	// Removed and erasing records stay hidden; a late heartbeat must not
	// bring them back or rewrite their personal fields.
	if old, ok := s.providerRecords[p.ID]; ok && old.DeletedAt != nil {
		return
	}
	cp := p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	s.providerRecords[p.ID] = &cp
}

func (s *MemoryStore) GetProviderRecord(_ context.Context, id string) (*store.ProviderRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	p, ok := s.providerRecords[id]
	if !ok || p.DeletedAt != nil {
		return nil, fmt.Errorf("provider %q not found", id)
	}
	cp := *p
	if p.Location != nil {
		loc := *p.Location
		cp.Location = &loc
	}
	return &cp, nil
}

func (s *MemoryStore) GetMDAChainBySerial(_ context.Context, serial string) (json.RawMessage, error) {
	if serial == "" {
		return nil, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Scan all records (not just the serial-indexed latest) so a newer empty-chain
	// row cannot shadow a chain-bearing one from a prior connection. Pick the most
	// recently seen non-empty chain.
	var best *store.ProviderRecord
	for _, p := range s.providerRecords {
		if p.SerialNumber != serial || len(p.MDACertChain) == 0 || p.DeletedAt != nil {
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

func (s *MemoryStore) ListProvidersByAccount(_ context.Context, accountID string) ([]store.ProviderRecord, error) {
	if accountID == "" {
		return []store.ProviderRecord{}, nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	records := make([]store.ProviderRecord, 0)
	for _, p := range s.providerRecords {
		if p.AccountID == accountID && p.DeletedAt == nil {
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

func (s *MemoryStore) DeleteProvidersBySerial(_ context.Context, ownerAccountID, serialOrID string) (int, error) {
	if ownerAccountID == "" || serialOrID == "" {
		return 0, nil
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.accountAdmissionLocked(ownerAccountID); err != nil {
		return 0, err
	}

	// Iterate the full record map (not just the serial index) so historical
	// duplicate rows sharing a serial are all caught. Match by serial OR id, but
	// only delete rows owned by the caller — rows owned by another account are
	// skipped and not counted, leaving the caller to decide 403 vs 404.
	var matched []string
	for id, rec := range s.providerRecords {
		if rec.AccountID != ownerAccountID || rec.DeletedAt != nil {
			continue
		}
		if (rec.SerialNumber == serialOrID && rec.SerialNumber != "") || rec.ID == serialOrID {
			matched = append(matched, id)
		}
	}

	now := time.Now().UTC()
	for _, id := range matched {
		s.providerRecords[id].DeletedAt = &now
		delete(s.reputationRecords, id)
		// usage, provider_earnings and provider_sessions are intentionally
		// preserved — they hold money/uptime history.
	}
	return len(matched), nil
}

func (s *MemoryStore) UpsertReputation(_ context.Context, providerID string, rep store.ReputationRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	cp := rep
	s.reputationRecords[providerID] = &cp
	return nil
}

func (s *MemoryStore) GetReputation(_ context.Context, providerID string) (*store.ReputationRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	rep, ok := s.reputationRecords[providerID]
	if !ok {
		return nil, fmt.Errorf("reputation for provider %q: %w", providerID, store.ErrNotFound)
	}
	cp := *rep
	return &cp, nil
}
