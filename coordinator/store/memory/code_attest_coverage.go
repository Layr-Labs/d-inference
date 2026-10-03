package memory

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/internal/shared"
)

func cloneCodeAttestation(r store.CodeAttestation) store.CodeAttestation {
	if r.ContinuousCoverageUntil != nil {
		t := *r.ContinuousCoverageUntil
		r.ContinuousCoverageUntil = &t
	}
	return r
}

func sameCodeProof(a, b store.CodeAttestation) bool {
	return a.SEPubKey == b.SEPubKey && a.Version == b.Version && a.APNsToken == b.APNsToken && a.NodePublicKey == b.NodePublicKey && a.BinaryHash == b.BinaryHash && a.AttestedAt.Equal(b.AttestedAt)
}

// AdvanceCodeAttestationCoverage never inserts or replaces proof. A delayed
// coverage write cannot resurrect a deleted proof or cover a different process.
func (s *MemoryStore) AdvanceCodeAttestationCoverage(_ context.Context, rows []store.CodeAttestation) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range rows {
		old, ok := s.codeAttestations[r.SEPubKey]
		if !ok || !shared.ValidCodeCoverage(r) || !sameCodeProof(old, r) {
			continue
		}
		if old.ContinuousCoverageUntil == nil || r.ContinuousCoverageUntil.After(*old.ContinuousCoverageUntil) {
			old.ContinuousCoverageUntil = r.ContinuousCoverageUntil
			s.codeAttestations[r.SEPubKey] = cloneCodeAttestation(old)
		}
	}
	return nil
}
