package performance

import "github.com/eigeninference/d-inference/coordinator/protocol"

// Catalog owns reviewed records for one coordinator lifetime. Records are
// configured before serving and remain immutable on routing paths.
type Catalog struct {
	profiles map[string]*Profile
}

func NewCatalog(profiles ...*Profile) *Catalog {
	catalog := &Catalog{profiles: make(map[string]*Profile, len(profiles))}
	for _, profile := range profiles {
		if profile != nil {
			catalog.profiles[profile.ID] = profile
		}
	}
	return catalog
}

// Identity borrows the canonical accepted provider evidence while its owner
// holds the provider lock. A heartbeat supplies references, never trusted rates.
type Identity struct {
	Version      string
	Hardware     protocol.Hardware
	Models       []protocol.ModelInfo
	Capacity     *protocol.BackendCapacity
	ThermalState string
}

func (c *Catalog) Qualified(identity Identity, model string) *Profile {
	if c == nil || identity.Capacity == nil || (identity.ThermalState != "" && identity.ThermalState != "nominal") {
		return nil
	}
	for _, slot := range identity.Capacity.Slots {
		if slot.Model != model || slot.PerformanceProfile == nil || slot.KVBackend == nil {
			continue
		}
		ref := slot.PerformanceProfile
		profile := c.profiles[ref.ID]
		if !profile.Valid() || profile.ModelID != model || profile.ProviderVersion != identity.Version ||
			profile.RuntimeRevision != ref.RuntimeRevision || !profile.MTP.Equal(ref.MTP) || profile.KVBackend != *slot.KVBackend ||
			profile.ChipName != identity.Hardware.ChipName || uint64(profile.GPUCores) != uint64(identity.Hardware.GPUCores) ||
			profile.MemoryGB != uint64(identity.Hardware.MemoryGB) || ref.ContextTokens <= 0 || ref.ContextTokens > profile.ContextTokensMax {
			return nil
		}
		for _, info := range identity.Models {
			if info.ID == model && info.WeightHash == profile.ArtifactSHA256 {
				return profile
			}
		}
	}
	return nil
}
