package memory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *MemoryStore) ListProviderTrustReuse(_ context.Context) ([]store.ProviderTrustReuse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]store.ProviderTrustReuse, 0, len(s.providerTrustReuse))
	for _, rec := range s.providerTrustReuse {
		out = append(out, rec)
	}
	return out, nil
}

func (s *MemoryStore) UpsertProviderTrustReuse(_ context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return store.ProviderTrustReuseWriteResult{}, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.erasedSEOwnerLocked(rec.SEPubKey, "") {
		return store.ProviderTrustReuseWriteResult{}, store.ErrErasureConflict
	}
	current, ok := s.providerTrustReuse[rec.SEPubKey]
	if ok && (current.RevokedAt != nil ||
		current.RevocationGeneration != expectedRevocationGeneration) {
		return store.ProviderTrustReuseWriteResult{
			EvidenceGeneration:   current.EvidenceGeneration,
			RevocationGeneration: current.RevocationGeneration,
		}, nil
	}
	rec.RevocationGeneration = expectedRevocationGeneration
	if ok {
		rec.RevocationEventID = current.RevocationEventID
		rec.EvidenceGeneration = current.EvidenceGeneration + 1
	}
	if rec.EvidenceGeneration == 0 {
		rec.EvidenceGeneration = 1
	}
	s.providerTrustReuse[rec.SEPubKey] = rec
	return store.ProviderTrustReuseWriteResult{
		Applied:              true,
		EvidenceGeneration:   rec.EvidenceGeneration,
		RevocationGeneration: rec.RevocationGeneration,
	}, nil
}

func (s *MemoryStore) RecoverProviderTrustReuse(_ context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return store.ProviderTrustReuseWriteResult{}, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.erasedSEOwnerLocked(rec.SEPubKey, "") {
		return store.ProviderTrustReuseWriteResult{}, store.ErrErasureConflict
	}
	current, ok := s.providerTrustReuse[rec.SEPubKey]
	if ok && current.RevocationGeneration != expectedRevocationGeneration {
		return store.ProviderTrustReuseWriteResult{
			EvidenceGeneration:   current.EvidenceGeneration,
			RevocationGeneration: current.RevocationGeneration,
		}, nil
	}
	rec.RevocationGeneration = expectedRevocationGeneration
	rec.RevokedAt = nil
	if ok {
		rec.RevocationEventID = current.RevocationEventID
		rec.EvidenceGeneration = current.EvidenceGeneration + 1
	}
	if rec.EvidenceGeneration == 0 {
		rec.EvidenceGeneration = 1
	}
	s.providerTrustReuse[rec.SEPubKey] = rec
	return store.ProviderTrustReuseWriteResult{
		Applied:              true,
		EvidenceGeneration:   rec.EvidenceGeneration,
		RevocationGeneration: rec.RevocationGeneration,
	}, nil
}

func (s *MemoryStore) AdvanceProviderTrustReuseCoverage(_ context.Context, seKeys []string, until time.Time) error {
	if len(seKeys) == 0 || until.IsZero() {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, seKey := range seKeys {
		rec, ok := s.providerTrustReuse[seKey]
		if !ok || rec.RevokedAt != nil || rec.TrustLevel != "hardware" {
			continue
		}
		if rec.ContinuousCoverageUntil != nil && !until.After(*rec.ContinuousCoverageUntil) {
			continue
		}
		u := until
		rec.ContinuousCoverageUntil = &u
		s.providerTrustReuse[seKey] = rec
	}
	return nil
}

func (s *MemoryStore) RevokeProviderTrustReuse(_ context.Context, seKey, revocationEventID string) (store.ProviderTrustReuse, error) {
	if seKey == "" || revocationEventID == "" {
		return store.ProviderTrustReuse{}, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rec := s.providerTrustReuse[seKey]
	if rec.RevocationEventID == revocationEventID {
		return rec, nil
	}
	rec.SEPubKey = seKey
	rec.TrustLevel = ""
	rec.ContinuousCoverageUntil = nil
	rec.RevocationGeneration++
	rec.RevocationEventID = revocationEventID
	now := time.Now().UTC()
	if rec.EvidenceGeneration == 0 {
		rec.EvidenceGeneration = 1
	}
	if rec.HardwareProofVerifiedAt.IsZero() {
		rec.HardwareProofVerifiedAt = now
	}
	rec.RevokedAt = &now
	s.providerTrustReuse[seKey] = rec
	return rec, nil
}
