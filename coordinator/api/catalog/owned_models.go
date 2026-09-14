package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// OwnedModelEntries assembles the /v1/models view for a self-route-only
// key: the account's own live machine models instead of the public catalog.
// Owned catalog builds behind an active public alias are presented under the
// alias id — the documented, consumer-facing name that self-route inference
// resolves too — with the concrete quant builds hidden, mirroring the public
// listing. includeHidden re-exposes those covered builds so retrieve-by-exact-
// id keeps working (parity with the public GET /v1/models/{id}, which serves
// hidden builds via listModelEntries(true)).
func (s *Controller) OwnedModelEntries(accountID string, includeHidden bool) []types.ModelEntry {
	models := s.registry.OwnedModels(accountID)
	byID := make(map[string]registry.AggregateModel, len(models))
	for _, m := range models {
		byID[m.ID] = m
	}

	aliases, err := s.store().ListModelAliases()
	if err != nil {
		// Degrade to the raw build listing rather than hiding the owner's
		// models outright.
		s.logger.Error("model registry: failed to list aliases for self-route models", "error", err)
		aliases = nil
	}

	covered := make(map[string]struct{})
	data := make([]types.ModelEntry, 0, len(models))
	for _, a := range aliases {
		if !a.Active || a.DesiredBuild == "" {
			continue
		}
		// Owned members: the alias's live builds this account's machines
		// actually serve. Retired builds stay raw — the alias would not
		// resolve to them for inference.
		members := make([]registry.AggregateModel, 0, 2)
		for _, b := range []string{a.DesiredBuild, a.PreviousBuild} {
			if m, ok := byID[b]; b != "" && ok {
				members = append(members, m)
			}
		}
		if len(members) == 0 {
			continue
		}
		// Primary member (desired-first order above) carries the metadata;
		// provider counts aggregate across members, mirroring the public
		// alias entry's capacity roll-up.
		agg := members[0]
		for _, m := range members[1:] {
			agg.Providers += m.Providers
			agg.AttestedProviders += m.AttestedProviders
		}
		agg.ID = a.AliasID
		// An alias spans quants; omit the per-build quant like the public list.
		agg.Quantization = ""
		entry := ownedModelEntry(agg)
		if a.DisplayName != "" {
			entry.Name = a.DisplayName
			entry.Metadata.DisplayName = a.DisplayName
		}
		data = append(data, entry)
		for _, m := range members {
			covered[m.ID] = struct{}{}
		}
	}

	for _, m := range models {
		if _, hidden := covered[m.ID]; hidden && !includeHidden {
			continue
		}
		data = append(data, ownedModelEntry(m))
	}
	return data
}

// ownedModelEntry converts one owned-model aggregate into the consumer-facing
// entry shape shared by the self-route list and retrieve endpoints.
func ownedModelEntry(m registry.AggregateModel) types.ModelEntry {
	metadata := types.ModelMetadata{
		ModelType:         m.ModelType,
		Quantization:      m.Quantization,
		ProviderCount:     m.Providers,
		AttestedProviders: m.AttestedProviders,
		TrustLevel:        string(m.TrustLevel),
		RoutableProviders: m.Providers,
		CanAccept:         m.Providers > 0,
	}
	if m.Attestation != nil {
		metadata.Attestation = &types.ModelAttestation{
			SecureEnclave: m.Attestation.SecureEnclave,
			SIPEnabled:    m.Attestation.SIPEnabled,
			SecureBoot:    m.Attestation.SecureBoot,
		}
	}
	return types.ModelEntry{
		ID:            m.ID,
		Object:        "model",
		OwnedBy:       "self",
		Name:          m.ID,
		HuggingFaceID: m.ID,
		Quantization:  m.Quantization,
		Metadata:      metadata,
	}
}
