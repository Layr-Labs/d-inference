package releases

import (
	"fmt"

	compiledpolicy "github.com/eigeninference/d-inference/coordinator/internal/api/releases/compiledpolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
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
func (s *Owner) SyncBinaryHashes() error {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()
	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		if last := s.releaseTrustPolicy.Load(); last != nil {
			s.logger.Error("release inventory unavailable; retaining last-known-good release policy",
				"generation", last.Generation,
				"error", err,
			)
			s.ddIncr("release_policy.sync_failure", []string{"outcome:retained_last_known_good"})
			return fmt.Errorf("sync binary hashes: %w", err)
		}
		// Cold start: no last-known-good policy exists. Publish deny-all so a
		// half-started coordinator cannot route on an unknown inventory.
		generation := s.releaseTrustPolicyGeneration.Add(1)
		trustSnapshot := compiledpolicy.New(generation, true)
		s.releaseTrustPolicy.Store(trustSnapshot)
		if s.registry != nil {
			s.registry.SetReleasePolicyGeneration(trustSnapshot.Generation, true, nil)
		}
		s.binaryHashPolicyMu.Lock()
		s.releaseKnownBinaryHashes = make(map[string]bool)
		s.releaseBinaryHashPolicyConfigured = true
		s.rebuildBinaryHashPolicyLocked()
		s.binaryHashPolicyMu.Unlock()
		s.logger.Error("release inventory unavailable at cold start; published deny-all release policy",
			"generation", generation,
			"error", err,
		)
		s.ddIncr("release_policy.sync_failure", []string{"outcome:cold_start_deny_all"})
		return fmt.Errorf("sync binary hashes: %w", err)
	}

	hashes := make(map[string]bool)
	generation := s.releaseTrustPolicyGeneration.Add(1)
	everConfigured := s.releaseInventoryEverConfigured.Load()
	if len(releases) > 0 {
		s.releaseInventoryEverConfigured.Store(true)
		everConfigured = true
	}
	trustSnapshot := compiledpolicy.New(generation, everConfigured)

	policyConfigured := false
	for _, r := range releases {
		if !r.Active {
			continue
		}
		policyConfigured = true
		normalized, err := NormalizeSHA256Hex(r.BinaryHash, "release.binary_hash")
		if err != nil {
			s.logger.Warn("invalid release binary hash ignored",
				"version", r.Version,
				"platform", r.Platform,
				"error", err,
			)
			continue
		}
		hashes[normalized] = true
		trustSnapshot = trustSnapshot.WithRelease(&r, normalized)
	}
	if n := s.publishReleaseTrustPolicy(trustSnapshot); n > 0 {
		s.logger.Info("release policy refresh left providers without current evidence; re-challenging immediately",
			"generation", trustSnapshot.Generation, "providers", n)
	}

	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = policyConfigured || everConfigured
	s.rebuildBinaryHashPolicyLocked()
	knownHashCount := len(s.knownBinaryHashes)
	effectivePolicyConfigured := s.binaryHashPolicyConfigured
	s.binaryHashPolicyMu.Unlock()

	s.logger.Info("binary hashes synced from releases", "known_hashes", knownHashCount, "policy_configured", effectivePolicyConfigured)
	return nil
}

// convergeReleasePolicyWithCommittedRelease folds an already-committed release
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
func (s *Owner) convergeReleasePolicyWithCommittedRelease(release *store.Release, cause error) {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()

	normalized, err := NormalizeSHA256Hex(release.BinaryHash, "release.binary_hash")
	if err != nil {
		// Unreachable for the register handler (the hash was validated before
		// the row committed), and a full rebuild would skip such a row too.
		s.logger.Error("committed release has invalid binary hash; policy not converged",
			"version", release.Version, "platform", release.Platform, "error", err)
		return
	}

	generation := s.releaseTrustPolicyGeneration.Add(1)
	s.releaseInventoryEverConfigured.Store(true)
	trustSnapshot := compiledpolicy.Retain(s.releaseTrustPolicy.Load(), generation, true, release.Version, release.Platform)
	trustSnapshot = trustSnapshot.WithRelease(release, normalized)
	s.publishReleaseTrustPolicy(trustSnapshot)

	hashes := make(map[string]bool, len(trustSnapshot.Inventory()))
	for hash := range trustSnapshot.Inventory() {
		hashes[hash] = true
	}
	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = true
	s.rebuildBinaryHashPolicyLocked()
	s.binaryHashPolicyMu.Unlock()

	s.logger.Warn("release inventory unreadable after registration; converged policy from the committed release",
		"version", release.Version,
		"platform", release.Platform,
		"generation", generation,
		"error", cause,
	)
	s.ddIncr("release_policy.sync_failure", []string{"outcome:converged_from_mutation"})
}

// convergeReleasePolicyWithCommittedDeactivation folds an already-committed
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
func (s *Owner) convergeReleasePolicyWithCommittedDeactivation(version, platform string, cause error) {
	s.releasePolicySyncMu.Lock()
	defer s.releasePolicySyncMu.Unlock()

	last := s.releaseTrustPolicy.Load()
	generation := s.releaseTrustPolicyGeneration.Add(1)
	// Deactivation never un-configures the inventory: once releases have been
	// published the evidence gate stays required, exactly as a full rebuild
	// over the remaining (possibly empty) release set would keep it.
	required := s.releaseInventoryEverConfigured.Load()
	if last != nil && last.Required {
		required = true
	}
	trustSnapshot := compiledpolicy.Retain(last, generation, required, version, platform)
	s.publishReleaseTrustPolicy(trustSnapshot)

	hashes := make(map[string]bool, len(trustSnapshot.Inventory()))
	for hash := range trustSnapshot.Inventory() {
		hashes[hash] = true
	}
	s.binaryHashPolicyMu.Lock()
	s.releaseKnownBinaryHashes = hashes
	s.releaseBinaryHashPolicyConfigured = len(hashes) > 0 || required
	s.rebuildBinaryHashPolicyLocked()
	s.binaryHashPolicyMu.Unlock()

	s.logger.Warn("release inventory unreadable after deactivation; converged policy from the committed deactivation",
		"version", version,
		"platform", platform,
		"generation", generation,
		"error", cause,
	)
	s.ddIncr("release_policy.sync_failure", []string{"outcome:converged_from_mutation"})
}
