package releasepolicy

import (
	"fmt"
)

// SyncRuntimeManifest builds the runtime manifest from active releases.
// Called after a release is registered to auto-update the expected hashes.
func (s *Manager) SyncRuntimeManifest() error {
	releases, err := s.deps.Store().ListReleasesWithError()
	if err != nil {
		s.deps.Logger().Warn("SyncRuntimeManifest: release inventory unavailable; keeping existing manifest",
			"error", err)
		return fmt.Errorf("sync runtime manifest: %w", err)
	}

	// Minimum provider version is set manually via EIGENINFERENCE_MIN_PROVIDER_VERSION
	// env var. It is NOT auto-derived from the latest release — pushing a new release
	// should not instantly knock all existing providers offline.

	// Every hash — python, runtime, AND each template name including
	// mlx_metallib — is unioned into a SET across ALL active releases.
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
		if r.PythonHash != "" {
			manifest.PythonHashes[r.PythonHash] = true
			hasAny = true
		}
		if r.RuntimeHash != "" {
			manifest.RuntimeHashes[r.RuntimeHash] = true
			hasAny = true
		}
		if manifest.addTemplateHashPairs(r.TemplateHashes) {
			hasAny = true
		}
		if r.MetallibHash != "" {
			normalized, err := NormalizeSHA256Hex(r.MetallibHash, "release.metallib_hash")
			if err != nil {
				s.deps.Logger().Warn("invalid release metallib hash ignored",
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
		s.knownRuntimeManifest = manifest
		s.deps.Logger().Info("runtime manifest synced from releases",
			"python_hashes", len(manifest.PythonHashes),
			"runtime_hashes", len(manifest.RuntimeHashes),
			"template_hashes", len(manifest.TemplateHashes),
			"template_hash_sets", manifest.templateHashSetSizes(),
		)
	} else if len(releases) > 0 {
		// Explicit empty: releases exist but none have hashes. Clear manifest.
		s.knownRuntimeManifest = nil
		s.deps.Logger().Info("runtime manifest cleared: releases exist but none have runtime hashes")
	} else {
		// Empty releases slice (not nil — nil is handled above). No releases
		// at all, which is only expected on a fresh coordinator. Keep
		// existing manifest if one exists.
		if s.knownRuntimeManifest != nil {
			s.deps.Logger().Warn("SyncRuntimeManifest: zero releases returned, keeping existing manifest")
			return nil
		}
		s.knownRuntimeManifest = nil
	}

	s.RevalidateConnectedProviders()
	return nil
}
