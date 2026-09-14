package memory

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

func (s *Store) ListProviderTrustReuse(_ context.Context) ([]contracts.ProviderTrustReuse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]contracts.ProviderTrustReuse, 0, len(s.providerTrustReuse))
	for _, rec := range s.providerTrustReuse {
		out = append(out, rec)
	}
	return out, nil
}

func (s *Store) UpsertProviderTrustReuse(_ context.Context, rec contracts.ProviderTrustReuse, expectedRevocationGeneration uint64) (contracts.ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return contracts.ProviderTrustReuseWriteResult{}, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current, ok := s.providerTrustReuse[rec.SEPubKey]
	if ok && (current.RevokedAt != nil ||
		current.RevocationGeneration != expectedRevocationGeneration) {
		return contracts.ProviderTrustReuseWriteResult{
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
	return contracts.ProviderTrustReuseWriteResult{
		Applied:              true,
		EvidenceGeneration:   rec.EvidenceGeneration,
		RevocationGeneration: rec.RevocationGeneration,
	}, nil
}

func (s *Store) RecoverProviderTrustReuse(_ context.Context, rec contracts.ProviderTrustReuse, expectedRevocationGeneration uint64) (contracts.ProviderTrustReuseWriteResult, error) {
	if rec.SEPubKey == "" {
		return contracts.ProviderTrustReuseWriteResult{}, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current, ok := s.providerTrustReuse[rec.SEPubKey]
	if ok && current.RevocationGeneration != expectedRevocationGeneration {
		return contracts.ProviderTrustReuseWriteResult{
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
	return contracts.ProviderTrustReuseWriteResult{
		Applied:              true,
		EvidenceGeneration:   rec.EvidenceGeneration,
		RevocationGeneration: rec.RevocationGeneration,
	}, nil
}

func (s *Store) AdvanceProviderTrustReuseCoverage(_ context.Context, seKeys []string, until time.Time) error {
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

func (s *Store) RevokeProviderTrustReuse(_ context.Context, seKey, revocationEventID string) (contracts.ProviderTrustReuse, error) {
	if seKey == "" || revocationEventID == "" {
		return contracts.ProviderTrustReuse{}, nil
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
