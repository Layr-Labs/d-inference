package releases

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Owner) revalidateConnectedProvidersAgainstRuntimePolicy() {
	// Release-inventory errors are already guarded in SyncRuntimeManifest, which
	// returns the error before reaching this function.
	// A nil manifest here means releases exist but none carry runtime hashes,
	// i.e. an intentional manifest withdrawal. Providers must be derouted.

	manifest := s.runtimeManifest.Load()
	for _, providerID := range s.registry.ProviderIDs() {
		provider := s.registry.GetProvider(providerID)
		if provider == nil {
			continue
		}

		provider.Mu().Lock()
		templateHashes := registry.CloneStringMap(provider.TemplateHashes)
		version := provider.Version
		backend := provider.Backend

		// Manifest policy is coordinator-owned and can be withdrawn, rotated,
		// or rolled back independently of the connected process. Rebuild all
		// policy-derived state from scratch, but preserve FreshCodeAttested:
		// that proof remains bound to this connection's token, keys, and code.
		// The token/key/code/trust invalidation paths clear it separately.
		provider.RuntimeVerified = false
		provider.RuntimeManifestChecked = false
		provider.MetallibVerified = false
		provider.RuntimeCapabilities = nil

		if manifest == nil {
			// Manifest was withdrawn — keep the process proof, but deroute the
			// provider until policy once again approves its reported runtime.
		} else if s.belowMinProviderVersion(version) {
			tag := "version:" + version
			if version == "" {
				tag = "version:unknown"
			}
			s.ddIncr("provider_version_below_minimum", []string{"gate:manifest_sync", tag})
		} else {
			runtimeOK, _ := manifest.verifyForBackend(backend, templateHashes)
			provider.RuntimeVerified = runtimeOK
			provider.RuntimeManifestChecked = runtimeOK
			provider.MetallibVerified = runtimeOK &&
				RuntimeManifestApprovesMetallib(
					manifest, templateHashes)
		}
		provider.Mu().Unlock()
		if err := s.registry.ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
			s.logger.Warn("runtime policy capability reconciliation failed",
				"provider_id", providerID, "error", err)
		}
		if cleared := s.registry.ClearIneligiblePendingModelLoads(providerID); cleared > 0 {
			s.logger.Info("cleared pending model loads after runtime policy revocation",
				"provider_id", providerID, "count", cleared)
		}
	}
}

func RuntimeManifestApprovesMetallib(
	manifest *RuntimeManifest,
	reported map[string]string,
) bool {
	if manifest == nil {
		return false
	}
	return templateHashAccepted(manifest.TemplateHashes["mlx_metallib"], reported["mlx_metallib"])
}
