package memory

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store/contracts"
	"github.com/eigeninference/d-inference/coordinator/store/internal/attestrecord"
	"github.com/eigeninference/d-inference/coordinator/store/internal/recordutil"
)

// AdvanceCodeAttestationCoverage never inserts or replaces proof. A delayed
// coverage write cannot resurrect a deleted proof or cover a different process.
func (s *Store) AdvanceCodeAttestationCoverage(_ context.Context, rows []contracts.CodeAttestation) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range rows {
		old, ok := s.codeAttestations[r.SEPubKey]
		if !ok || !attestrecord.ValidCodeCoverage(r) || !attestrecord.SameCodeProof(old, r) {
			continue
		}
		if old.ContinuousCoverageUntil == nil || r.ContinuousCoverageUntil.After(*old.ContinuousCoverageUntil) {
			old.ContinuousCoverageUntil = r.ContinuousCoverageUntil
			s.codeAttestations[r.SEPubKey] = recordutil.CloneCodeAttestation(old)
		}
	}
	return nil
}
