package releases

import (
	"fmt"

	compiledpolicy "github.com/eigeninference/d-inference/coordinator/internal/api/releases/compiledpolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// publishReleaseTrustPolicy carries still-approved evidence into the new
// generation and challenges every provider left without it. All normal sync and
// committed-mutation recovery paths use this order. Caller holds
// releasePolicySyncMu. Cold-start deny-all intentionally has its own path: it
// has no previous evidence to carry forward and no immediate challenge loop.
func (s *Owner) publishReleaseTrustPolicy(snapshot *compiledpolicy.Snapshot) int {
	s.releaseTrustPolicy.Store(snapshot)
	if s.registry == nil {
		return 0
	}
	needChallenge := s.registry.SetReleasePolicyGeneration(snapshot.Generation, snapshot.Required,
		func(evidence registry.ApplicationEvidence) bool {
			return releaseEvidenceStillApproved(snapshot, evidence)
		})
	s.registry.SetAppAttestServingPolicy(s.appAttestServing(), snapshot.Generation)
	for _, providerID := range needChallenge {
		if provider := s.registry.GetProvider(providerID); provider != nil {
			provider.RequestImmediateChallenge()
		}
	}
	if len(needChallenge) > 0 {
		s.ddIncr("release_policy.evidence_invalidated", []string{fmt.Sprintf("providers:%d", len(needChallenge))})
	}
	return len(needChallenge)
}
