package memory

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/attestrecord"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
)

func (s *Store) ListCodeAttestations(_ context.Context) ([]contracts.CodeAttestation, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]contracts.CodeAttestation, 0, len(s.codeAttestations))
	for _, rec := range s.codeAttestations {
		out = append(out, recordutil.CloneCodeAttestation(rec))
	}
	return out, nil
}

func (s *Store) UpsertCodeAttestation(_ context.Context, rec contracts.CodeAttestation) error {
	if rec.SEPubKey == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	if old, ok := s.codeAttestations[rec.SEPubKey]; !ok || !rec.AttestedAt.Before(old.AttestedAt) {
		if ok && attestrecord.SameCodeProof(old, rec) && old.ContinuousCoverageUntil != nil && (rec.ContinuousCoverageUntil == nil || old.ContinuousCoverageUntil.After(*rec.ContinuousCoverageUntil)) {
			rec.ContinuousCoverageUntil = old.ContinuousCoverageUntil
		}
		s.codeAttestations[rec.SEPubKey] = recordutil.CloneCodeAttestation(rec)
	}
	return nil
}

func (s *Store) DeleteCodeAttestation(_ context.Context, seKey string) error {
	if seKey == "" {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.codeAttestations, seKey)
	return nil
}
