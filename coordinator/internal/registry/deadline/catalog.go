package deadline

import (
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Catalog retains review-controlled records configured before serving. Provider
// references select evidence; live telemetry cannot create a reviewed record.
type Catalog struct{ profiles map[string]*Profile }

func NewCatalog(profiles ...*Profile) *Catalog {
	c := &Catalog{profiles: make(map[string]*Profile, len(profiles))}
	for _, p := range profiles {
		if p != nil {
			c.profiles[p.ID] = p
		}
	}
	return c
}

// DecodeProfiles rejects the entire compiled catalog on any invalid or duplicate
// record. Its output is detached configuration, not live routing state.
func DecodeProfiles(raw string) []*Profile {
	var profiles []*Profile
	if err := json.Unmarshal([]byte(raw), &profiles); err != nil || profiles == nil {
		return nil
	}
	seen := make(map[string]bool, len(profiles))
	for _, p := range profiles {
		if !p.Valid() || seen[p.ID] {
			return nil
		}
		seen[p.ID] = true
	}
	return profiles
}

type Identity struct {
	Version  string
	Hardware protocol.Hardware
	Models   []protocol.ModelInfo
	Capacity *protocol.BackendCapacity
	Metrics  protocol.SystemMetrics
}

func (c *Catalog) Qualified(identity Identity, model string) *Profile {
	if c == nil || !NominalPosture(identity.Capacity, identity.Metrics) {
		return nil
	}
	for _, slot := range identity.Capacity.Slots {
		if slot.Model != model || slot.DeadlineProfile == nil || slot.KVBackend == nil {
			continue
		}
		ref := slot.DeadlineProfile
		profile := c.profiles[ref.ID]
		if !profile.Valid() || profile.ModelID != model || profile.ProviderVersion != identity.Version ||
			profile.RuntimeRevision != ref.RuntimeRevision || !profile.MTP.Equal(ref.MTP) || profile.KVBackend != *slot.KVBackend ||
			profile.ChipName != identity.Hardware.ChipName || uint64(profile.GPUCores) != uint64(identity.Hardware.GPUCores) ||
			profile.MemoryGB != uint64(identity.Hardware.MemoryGB) || profile.ConfiguredContextTokens != ref.ConfiguredContextTokens ||
			profile.EffectiveMaxConcurrency != ref.EffectiveMaxConcurrency || profile.PrefillChunkSize != ref.PrefillChunkSize ||
			!sameOptionalInt(profile.SoloPrefillStripeTokens, ref.SoloPrefillStripeTokens) ||
			profile.MaxConcurrentPartialPrefills != ref.MaxConcurrentPartialPrefills || !sameOptionalInt(profile.MixedPrefillTokenCap, ref.MixedPrefillTokenCap) ||
			!sameOptionalInt(profile.MinimumWholeMacQuiescenceMS, ref.MinimumWholeMacQuiescenceMS) ||
			!sameOptionalInt(profile.MinimumNominalStabilityMS, ref.MinimumNominalStabilityMS) || profile.PowerMode != ref.PowerMode {
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

func sameOptionalInt(a, b *int) bool {
	return (a == nil && b == nil) || (a != nil && b != nil && *a == *b)
}
