package network

import "github.com/eigeninference/d-inference/coordinator/registry"

// Fleet is the existing registry's read-only view. ForEachProvider retains the
// registry's synchronization and does not expose new locks or mutable state.
type Fleet interface {
	PublicProviderModels() map[string]registry.PublicProviderModelSnapshot
	ForEachProvider(func(*registry.Provider))
	CodeAttestationCoverage() (int, int)
	CodeAttestationEnforced() bool
	CountProvidersWithCurrentApplicationEvidence() (int, int)
	ApplicationEvidenceModelCoverage() map[string]registry.ModelEvidenceCoverage
	ReleasePolicyEnforced() bool
	NetworkUtilizationSnapshot() registry.NetworkUtilization
}
