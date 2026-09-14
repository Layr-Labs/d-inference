package releasepolicy

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ConvergeCommittedRelease folds an already-committed release
// registration into the in-memory release trust policy when the post-mutation
// inventory read failed. GET /v1/releases/latest serves the committed row
// straight from the store, so retaining the pre-registration snapshot would
// distribute a release the policy can never authorize — providers installing it
// could never earn evidence and, with no background resync, would stay
// unroutable indefinitely. The merged snapshot is exactly what a successful
// rebuild over "last-known-good inventory + this row" publishes: entries for
// the same version/platform are replaced, everything else is carried forward
// (so still-approved evidence survives and routine registration never deroutes
// the fleet), and the newly saved release is immediately authorized. The next
// successful sync rebuilds from the exact inventory.
func (s *Manager) ConvergeCommittedRelease(release *store.Release, cause error) {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()

	normalized, err := NormalizeSHA256Hex(release.BinaryHash, "release.binary_hash")
	if err != nil {
		// Unreachable for the register handler (the hash was validated before
		// the row committed), and a full rebuild would skip such a row too.
		s.deps.Logger().Error("committed release has invalid binary hash; policy not converged",
			"version", release.Version, "platform", release.Platform, "error", err)
		return
	}

	generation := s.releaseTrustPolicyGeneration.Add(1)
	s.releaseInventoryEverConfigured.Store(true)
	trustSnapshot := retainedReleaseTrustPolicy(s.releaseTrustPolicy.Load(), generation, true, release.Version, release.Platform)
	trustSnapshot.addRelease(release, normalized)
	s.publishReleaseTrustPolicy(trustSnapshot)

	hashes := make(map[string]bool, len(trustSnapshot.byBinaryHash))
	for hash := range trustSnapshot.byBinaryHash {
		hashes[hash] = true
	}
	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = true
	s.rebuildBinaryHashPolicyLocked()
	s.binaryHashPolicyMu.Unlock()

	s.deps.Logger().Warn("release inventory unreadable after registration; converged policy from the committed release",
		"version", release.Version,
		"platform", release.Platform,
		"generation", generation,
		"error", cause,
	)
	s.deps.Incr("release_policy.sync_failure", []string{"outcome:converged_from_mutation"})
}

// ConvergeCommittedDeactivation folds an already-committed
// release deactivation into the in-memory release trust policy when the
// post-mutation inventory read failed. Retaining the pre-deactivation snapshot
// would keep authorizing the deactivated release indefinitely — there is no
// background resync, so in a force=true emergency pull of a compromised
// release the affected providers would keep routing until an admin retried.
// The merged snapshot is exactly what a successful rebuild over
// "last-known-good inventory minus this row" publishes: entries for the
// deactivated version/platform are dropped, everything else is carried forward
// (so still-approved evidence survives and pulling one release never deroutes
// the rest of the fleet), and providers whose evidence rested on the
// deactivated release are invalidated and kicked for an immediate
// re-challenge. The next successful sync rebuilds from the exact inventory.
func (s *Manager) ConvergeCommittedDeactivation(version, platform string, cause error) {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()

	last := s.releaseTrustPolicy.Load()
	generation := s.releaseTrustPolicyGeneration.Add(1)
	// Deactivation never un-configures the inventory: once releases have been
	// published the evidence gate stays required, exactly as a full rebuild
	// over the remaining (possibly empty) release set would keep it.
	required := s.releaseInventoryEverConfigured.Load()
	if last != nil && last.required {
		required = true
	}
	trustSnapshot := retainedReleaseTrustPolicy(last, generation, required, version, platform)
	s.publishReleaseTrustPolicy(trustSnapshot)

	hashes := make(map[string]bool, len(trustSnapshot.byBinaryHash))
	for hash := range trustSnapshot.byBinaryHash {
		hashes[hash] = true
	}
	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = len(hashes) > 0 || required
	s.rebuildBinaryHashPolicyLocked()
	s.binaryHashPolicyMu.Unlock()

	s.deps.Logger().Warn("release inventory unreadable after deactivation; converged policy from the committed deactivation",
		"version", version,
		"platform", platform,
		"generation", generation,
		"error", cause,
	)
	s.deps.Incr("release_policy.sync_failure", []string{"outcome:converged_from_mutation"})
}
