package releases

import (
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// SyncRuntimeManifest builds the runtime manifest from active releases.
// Called after a release is registered to auto-update the expected hashes.
func (s *Owner) SyncRuntimeManifest() error {
	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		s.logger.Warn("SyncRuntimeManifest: release inventory unavailable; keeping existing manifest",
			"error", err)
		return fmt.Errorf("sync runtime manifest: %w", err)
	}

	// Minimum provider version is set manually via EIGENINFERENCE_MIN_PROVIDER_VERSION
	// env var. It is NOT auto-derived from the latest release — pushing a new release
	// should not instantly knock all existing providers offline.

	// Every template hash, including mlx_metallib, is unioned into a SET
	// across ALL active releases.
	// Releases overlap in production for the whole self-update window
	// (providers poll for updates every 30 minutes), so the manifest must
	// accept the runtime facts of every release a connected provider may
	// legitimately be running. Template hashes used to be single-valued per
	// name (newest release wins): registering v0.8.16 replaced the v0.8.15
	// metallib hash and derouted ~1,180 still-current providers at their next
	// challenge (2026-09-03 fleet brownout). Deactivating a release is the
	// mechanism that removes its hashes; iteration order is irrelevant.
	manifest := NewRuntimeManifest()
	hasAny := false
	for _, r := range releases {
		if !r.Active {
			continue
		}
		if manifest.addTemplateHashPairs(r.TemplateHashes) {
			hasAny = true
		}
		if r.MetallibHash != "" {
			normalized, err := NormalizeSHA256Hex(r.MetallibHash, "release.metallib_hash")
			if err != nil {
				s.logger.Warn("invalid release metallib hash ignored",
					"version", r.Version,
					"platform", r.Platform,
					"error", err,
				)
			} else if manifest.AddTemplateHash("mlx_metallib", normalized) {
				hasAny = true
			}
		}
	}

	if hasAny {
		s.runtimeManifest.Store(manifest)
		s.logger.Info("runtime manifest synced from releases",
			"template_hashes", len(manifest.TemplateHashes),
			"template_hash_sets", manifest.templateHashSetSizes(),
		)
	} else if len(releases) > 0 {
		// Explicit empty: releases exist but none have hashes. Clear manifest.
		s.runtimeManifest.Store(nil)
		s.logger.Info("runtime manifest cleared: releases exist but none have runtime hashes")
	} else {
		// Empty releases slice (not nil — nil is handled above). No releases
		// at all, which is only expected on a fresh coordinator. Keep
		// existing manifest if one exists.
		if s.runtimeManifest.Load() != nil {
			s.logger.Warn("SyncRuntimeManifest: zero releases returned, keeping existing manifest")
			return nil
		}
		s.runtimeManifest.Store(nil)
	}

	s.revalidateConnectedProvidersAgainstRuntimePolicy()
	return nil
}

// convergeRuntimeManifestWithCommittedRelease folds an already-committed
// release registration into the runtime manifest when the post-mutation
// inventory read failed, so a transient store hiccup cannot leave the manifest
// rejecting the runtime facts of the release that /v1/releases/latest is
// already distributing. Every hash set — including each per-template-name
// set — is additive, exactly like a full rebuild (which unions every active
// release): the previous release's fleet keeps passing while the newly saved
// release is accepted too. The next successful sync rebuilds from the exact
// inventory.
func (s *Owner) convergeRuntimeManifestWithCommittedRelease(release *store.Release, cause error) {
	merged := s.runtimeManifest.Load().clone()
	contributed := false
	if merged.addTemplateHashPairs(release.TemplateHashes) {
		contributed = true
	}
	if release.MetallibHash != "" {
		if normalized, err := NormalizeSHA256Hex(release.MetallibHash, "release.metallib_hash"); err == nil &&
			merged.AddTemplateHash("mlx_metallib", normalized) {
			contributed = true
		}
	}
	if !contributed {
		// The committed release carries no runtime facts; a full rebuild would
		// republish the union of the remaining releases — the current manifest.
		return
	}
	s.runtimeManifest.Store(merged)
	s.logger.Warn("release inventory unreadable after registration; converged runtime manifest from the committed release",
		"version", release.Version,
		"platform", release.Platform,
		"error", cause,
	)
	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

// convergeRuntimeManifestWithCommittedDeactivation folds an already-committed
// release deactivation into the runtime manifest when the post-mutation
// inventory read failed. Unlike registration (where the new release's facts
// are simply unioned in), deactivation cannot blindly subtract the pulled
// release's hashes — another active release may share them — so the manifest
// is rebuilt from the live release trust snapshot, which at this point already
// excludes the deactivated version/platform (SyncBinaryHashes either succeeded
// or was converged from the same committed deactivation first). Every hash
// set — including each per-template-name set — is the union of the remaining
// authorized releases, exactly like the full rebuild. Active releases whose
// binary hash failed normalization are absent from the snapshot and thus from
// this approximation; the next successful sync rebuilds from the exact
// inventory.
func (s *Owner) convergeRuntimeManifestWithCommittedDeactivation(version, platform string, cause error) {
	merged := NewRuntimeManifest()
	hasAny := false
	if snapshot := s.releaseTrustPolicy.Load(); snapshot != nil {
		for _, policies := range snapshot.ByBinaryHash {
			for _, policy := range policies {
				for name, hash := range policy.TemplateHashes {
					if merged.AddTemplateHash(name, hash) {
						hasAny = true
					}
				}
				if policy.MetallibHash != "" {
					if normalized, err := NormalizeSHA256Hex(policy.MetallibHash, "release.metallib_hash"); err == nil &&
						merged.AddTemplateHash("mlx_metallib", normalized) {
						hasAny = true
					}
				}
			}
		}
	}
	if !hasAny {
		// The deactivated row committed, so releases exist(ed) but none of the
		// remaining authorized ones carry runtime facts: explicit withdrawal,
		// exactly like the full rebuild's "releases exist but none have
		// hashes" branch. Providers proving the pulled release's facts must
		// not keep passing the manifest gate.
		merged = nil
	}
	s.runtimeManifest.Store(merged)
	s.logger.Warn("release inventory unreadable after deactivation; converged runtime manifest from the retained policy snapshot",
		"version", version,
		"platform", platform,
		"error", cause,
	)
	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}
