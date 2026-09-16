package releasepolicy

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// publishReleaseTrustPolicy carries still-approved evidence into the new
// generation and challenges every provider left without it. All normal sync and
// committed-mutation recovery paths use this order. Caller holds
// releasePolicySyncMu. Cold-start deny-all intentionally has its own path: it
// has no previous evidence to carry forward and no immediate challenge loop.
func (s *Manager) publishReleaseTrustPolicy(snapshot *Snapshot) int {
	s.releaseTrustPolicy.Store(snapshot)
	if s.deps.Registry() == nil {
		return 0
	}
	needChallenge := s.deps.Registry().SetReleasePolicyGeneration(snapshot.generation, snapshot.required,
		func(evidence registry.ApplicationEvidence) bool {
			return releaseEvidenceStillApproved(snapshot, evidence)
		})
	for _, providerID := range needChallenge {
		if provider := s.deps.Registry().GetProvider(providerID); provider != nil {
			provider.RequestImmediateChallenge()
		}
	}
	if len(needChallenge) > 0 {
		s.deps.Incr("release_policy.evidence_invalidated", []string{fmt.Sprintf("providers:%d", len(needChallenge))})
	}
	return len(needChallenge)
}
