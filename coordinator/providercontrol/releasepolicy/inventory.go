package releasepolicy

import (
	"fmt"
)

// SyncBinaryHashes rebuilds knownBinaryHashes from all active releases.
// Called at startup and after release changes.
//
// An inventory read failure is an OPERATIONAL condition, not a security signal:
// with a previously published policy the last-known-good snapshot is retained
// untouched (mirroring SyncRuntimeManifest's nil handling) so a store hiccup
// can never deroute a healthy fleet. Only a cold start with no prior snapshot
// publishes a deny-all generation — there is nothing known-good to retain, and
// startup refuses to proceed on the returned error.
func (s *Manager) SyncBinaryHashes() error {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()
	releases, err := s.deps.Store().ListReleasesWithError()
	if err != nil {
		if last := s.releaseTrustPolicy.Load(); last != nil {
			s.deps.Logger().Error("release inventory unavailable; retaining last-known-good release policy",
				"generation", last.generation,
				"error", err,
			)
			s.deps.Incr("release_policy.sync_failure", []string{"outcome:retained_last_known_good"})
			return fmt.Errorf("sync binary hashes: %w", err)
		}
		// Cold start: no last-known-good policy exists. Publish deny-all so a
		// half-started coordinator cannot route on an unknown inventory.
		generation := s.releaseTrustPolicyGeneration.Add(1)
		trustSnapshot := &Snapshot{
			generation:   generation,
			required:     true,
			byBinaryHash: make(map[string][]Release),
		}
		s.releaseTrustPolicy.Store(trustSnapshot)
		if s.deps.Registry() != nil {
			s.deps.Registry().SetReleasePolicyGeneration(trustSnapshot.generation, true, nil)
		}
		s.binaryHashPolicyMu.Lock()
		s.releaseKnownBinaryHashes = make(map[string]bool)
		s.releaseBinaryHashPolicyConfigured = true
		s.rebuildBinaryHashPolicyLocked()
		s.binaryHashPolicyMu.Unlock()
		s.deps.Logger().Error("release inventory unavailable at cold start; published deny-all release policy",
			"generation", generation,
			"error", err,
		)
		s.deps.Incr("release_policy.sync_failure", []string{"outcome:cold_start_deny_all"})
		return fmt.Errorf("sync binary hashes: %w", err)
	}

	hashes := make(map[string]bool)
	generation := s.releaseTrustPolicyGeneration.Add(1)
	everConfigured := s.releaseInventoryEverConfigured.Load()
	if len(releases) > 0 {
		s.releaseInventoryEverConfigured.Store(true)
		everConfigured = true
	}
	trustSnapshot := &Snapshot{
		generation:   generation,
		required:     everConfigured,
		byBinaryHash: make(map[string][]Release),
	}

	policyConfigured := false
	for _, r := range releases {
		if !r.Active {
			continue
		}
		policyConfigured = true
		normalized, err := NormalizeSHA256Hex(r.BinaryHash, "release.binary_hash")
		if err != nil {
			s.deps.Logger().Warn("invalid release binary hash ignored",
				"version", r.Version,
				"platform", r.Platform,
				"error", err,
			)
			continue
		}
		hashes[normalized] = true
		trustSnapshot.addRelease(&r, normalized)
	}
	if n := s.publishReleaseTrustPolicy(trustSnapshot); n > 0 {
		s.deps.Logger().Info("release policy refresh left providers without current evidence; re-challenging immediately",
			"generation", trustSnapshot.generation, "providers", n)
	}

	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = policyConfigured || everConfigured
	s.rebuildBinaryHashPolicyLocked()
	knownHashCount := len(s.knownBinaryHashes)
	effectivePolicyConfigured := s.binaryHashPolicyConfigured
	s.binaryHashPolicyMu.Unlock()

	s.deps.Logger().Info("binary hashes synced from releases", "known_hashes", knownHashCount, "policy_configured", effectivePolicyConfigured)
	return nil
}
