package api

import (
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// publishReleaseTrustPolicy carries still-approved evidence into the new
// generation and challenges every provider left without it. All normal sync and
// committed-mutation recovery paths use this order. Caller holds
// releasePolicySyncMu. Cold-start deny-all intentionally has its own path: it
// has no previous evidence to carry forward and no immediate challenge loop.
func (s *Server) publishReleaseTrustPolicy(snapshot *releaseTrustPolicySnapshot) int {
	s.releaseTrustPolicy.Store(snapshot)
	if s.registry == nil {
		return 0
	}
	needChallenge := s.registry.SetReleasePolicyGeneration(snapshot.Generation, snapshot.Required,
		func(evidence registry.ApplicationEvidence) bool {
			return releaseEvidenceStillApproved(snapshot, evidence)
		})
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

// retainedReleaseTrustPolicy copies every still-approved entry except the
// version/platform being replaced or deactivated. The published snapshot and
// its policy maps are immutable; only the new top-level slices are extended.
func retainedReleaseTrustPolicy(last *releaseTrustPolicySnapshot, generation uint64, required bool, version, platform string) *releaseTrustPolicySnapshot {
	snapshot := &releaseTrustPolicySnapshot{
		Generation: generation, Required: required,
		ByBinaryHash: make(map[string][]approvedReleasePolicy),
	}
	if last != nil {
		for hash, policies := range last.ByBinaryHash {
			for _, policy := range policies {
				if policy.Version != version || policy.Platform != platform {
					snapshot.ByBinaryHash[hash] = append(snapshot.ByBinaryHash[hash], policy)
				}
			}
		}
	}
	return snapshot
}

// addRelease projects a release whose binary hash the caller already validated.
// It preserves the release parser's last-value-wins template semantics.
func (snapshot *releaseTrustPolicySnapshot) addRelease(release *store.Release, normalizedHash string) {
	templates := make(map[string]string)
	for _, pair := range strings.Split(release.TemplateHashes, ",") {
		parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			templates[parts[0]] = parts[1]
		}
	}
	snapshot.ByBinaryHash[normalizedHash] = append(snapshot.ByBinaryHash[normalizedHash], approvedReleasePolicy{
		Version: release.Version, Platform: release.Platform, Backend: release.Backend,
		BinaryHash: normalizedHash, MetallibHash: release.MetallibHash,
		PythonHash: release.PythonHash, RuntimeHash: release.RuntimeHash,
		TemplateHashes: templates,
	})
}
