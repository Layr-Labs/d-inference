package releasepolicy

import (
	"maps"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Manager) RevalidateConnectedProviders() {
	// Release-inventory errors are already guarded in SyncRuntimeManifest, which
	// returns the error before reaching this function.
	// A nil manifest here means releases exist but none carry runtime hashes,
	// i.e. an intentional manifest withdrawal. Providers must be derouted.

	fleet := s.deps.Registry()
	if fleet == nil {
		return
	}
	for _, providerID := range fleet.ProviderIDs() {
		provider := fleet.GetProvider(providerID)
		if provider == nil {
			continue
		}

		provider.Mu().Lock()
		manifest := s.knownRuntimeManifest.Load()
		pythonHash := provider.PythonHash
		runtimeHash := provider.RuntimeHash
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
		} else if s.deps.MinimumVersion() != "" &&
			version != "" &&
			VersionLess(version, s.deps.MinimumVersion()) {
			s.deps.Incr("provider_version_below_minimum", []string{"gate:manifest_sync", "version:" + version})
		} else {
			runtimeOK, _ := s.VerifyRuntimeHashesForBackendWithManifest(
				manifest, backend,
				pythonHash,
				runtimeHash,
				templateHashes,
			)
			provider.RuntimeVerified = runtimeOK
			provider.RuntimeManifestChecked = runtimeOK
			provider.MetallibVerified = runtimeOK &&
				RuntimeManifestApprovesMetallib(
					manifest, templateHashes)
		}
		provider.Mu().Unlock()
		if err := fleet.ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
			s.deps.Logger().Warn("runtime policy capability reconciliation failed",
				"provider_id", providerID, "error", err)
		}
		if cleared := fleet.ClearIneligiblePendingModelLoads(providerID); cleared > 0 {
			s.deps.Logger().Info("cleared pending model loads after runtime policy revocation",
				"provider_id", providerID, "count", cleared)
		}
	}
}

// ApplyChallengeRuntimePolicy first records the exact signed runtime identity,
// then applies the current manifest policy when one exists. Policy withdrawal
// keeps runtime gates closed without invalidating an unchanged process proof;
// any changed or omitted identity clears FreshCodeAttested independently.
func (s *Manager) ApplyChallengeRuntimePolicy(
	provider *registry.Provider,
	resp *protocol.AttestationResponseMessage,
) (bool, bool, []protocol.RuntimeMismatch) {
	provider.Mu().Lock()
	manifest := s.knownRuntimeManifest.Load()
	policyActive := manifest != nil
	runtimeOK := false
	var mismatches []protocol.RuntimeMismatch
	if policyActive {
		runtimeOK, mismatches = s.VerifyRuntimeHashesForBackendWithManifest(
			manifest, provider.Backend, resp.PythonHash, resp.RuntimeHash, resp.TemplateHashes)
	}

	runtimeIdentityChanged :=
		resp.PythonHash != provider.PythonHash ||
			resp.RuntimeHash != provider.RuntimeHash ||
			!maps.EqualFunc(
				resp.TemplateHashes,
				provider.TemplateHashes,
				strings.EqualFold,
			)

	provider.RuntimeVerified = policyActive && runtimeOK
	provider.RuntimeManifestChecked = policyActive && runtimeOK
	provider.MetallibVerified = policyActive && runtimeOK &&
		RuntimeManifestApprovesMetallib(manifest, resp.TemplateHashes)
	if !provider.RuntimeVerified ||
		!provider.MetallibVerified ||
		runtimeIdentityChanged {
		provider.RuntimeCapabilities = nil
	}
	if runtimeIdentityChanged {
		provider.FreshCodeAttested = false
	}
	provider.PythonHash = resp.PythonHash
	provider.RuntimeHash = resp.RuntimeHash
	provider.TemplateHashes = registry.CloneStringMap(resp.TemplateHashes)
	provider.Mu().Unlock()
	return policyActive, runtimeOK, mismatches
}

// ApplyChallengeMinVersionPolicy clears only policy-derived runtime state when
// the coordinator temporarily raises its version floor. The unchanged process
// proof remains valid and can promote capabilities again if policy rolls back.
func (s *Manager) ApplyChallengeMinVersionPolicy(
	provider *registry.Provider,
) (string, bool) {
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	version := provider.Version
	if s.deps.MinimumVersion() == "" ||
		version == "" ||
		!VersionLess(version, s.deps.MinimumVersion()) {
		return version, true
	}
	provider.RuntimeVerified = false
	provider.RuntimeManifestChecked = false
	provider.MetallibVerified = false
	provider.RuntimeCapabilities = nil
	return version, false
}
