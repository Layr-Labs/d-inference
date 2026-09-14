package releasepolicy

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ConvergeCommittedRuntimeRelease folds an already-committed
// release registration into the runtime manifest when the post-mutation
// inventory read failed, so a transient store hiccup cannot leave the manifest
// rejecting the runtime facts of the release that /v1/releases/latest is
// already distributing. Every hash set — including each per-template-name
// set — is additive, exactly like a full rebuild (which unions every active
// release): the previous release's fleet keeps passing while the newly saved
// release is accepted too. The next successful sync rebuilds from the exact
// inventory.
func (s *Manager) ConvergeCommittedRuntimeRelease(release *store.Release, cause error) {
	merged := s.knownRuntimeManifest.clone()
	contributed := false
	if release.PythonHash != "" {
		merged.PythonHashes[release.PythonHash] = true
		contributed = true
	}
	if release.RuntimeHash != "" {
		merged.RuntimeHashes[release.RuntimeHash] = true
		contributed = true
	}
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
	s.knownRuntimeManifest = merged
	s.deps.Logger().Warn("release inventory unreadable after registration; converged runtime manifest from the committed release",
		"version", release.Version,
		"platform", release.Platform,
		"error", cause,
	)
	s.RevalidateConnectedProviders()
}

// ConvergeCommittedRuntimeDeactivation folds an already-committed
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
func (s *Manager) ConvergeCommittedRuntimeDeactivation(version, platform string, cause error) {
	merged := NewRuntimeManifest()
	hasAny := false
	if snapshot := s.releaseTrustPolicy.Load(); snapshot != nil {
		for _, policies := range snapshot.byBinaryHash {
			for _, policy := range policies {
				if policy.PythonHash != "" {
					merged.PythonHashes[policy.PythonHash] = true
					hasAny = true
				}
				if policy.RuntimeHash != "" {
					merged.RuntimeHashes[policy.RuntimeHash] = true
					hasAny = true
				}
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
	s.knownRuntimeManifest = merged
	s.deps.Logger().Warn("release inventory unreadable after deactivation; converged runtime manifest from the retained policy snapshot",
		"version", version,
		"platform", platform,
		"error", cause,
	)
	s.RevalidateConnectedProviders()
}
