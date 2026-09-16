package catalog

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func hideAliasBuild(hidden map[string]struct{}, catalogByID map[string]store.SupportedModel, buildID string) {
	if buildID == "" {
		return
	}
	if _, inCatalog := catalogByID[buildID]; inCatalog {
		hidden[buildID] = struct{}{}
	}
}

// aliasModelEntries builds consumer-facing /v1/models entries for active
// standard aliases and returns the concrete build ids they hide. OpenRouter-only
// aliases are deliberately excluded; they are discoverable only through the
// dedicated /v1/models/openrouter marketplace feed.
func (s *Controller) aliasModelEntries(
	capByModel map[string]*registry.ModelCapacity,
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
) ([]types.ModelEntry, map[string]struct{}, error) {
	hidden := make(map[string]struct{})
	aliases, err := s.store().ListModelAliases()
	if err != nil {
		return nil, nil, err
	}

	entries := make([]types.ModelEntry, 0, len(aliases))
	for _, a := range aliases {
		if !a.Active || a.OpenRouterOnly || a.DesiredBuild == "" {
			continue
		}
		// A consumer must only ever see the alias, never a concrete build behind
		// it. Hide EVERY build this alias references — desired, previous, AND the
		// retired lineage — from the standalone listing, even if the alias itself
		// isn't advertisable right now. (Capacity below aggregates only the
		// routable desired/previous members; retired builds are hide-only.)
		hideAliasBuild(hidden, catalogByID, a.DesiredBuild)
		hideAliasBuild(hidden, catalogByID, a.PreviousBuild)
		for _, b := range a.RetiredBuilds {
			hideAliasBuild(hidden, catalogByID, b)
		}
		// Primary build = the desired build when it's in the catalog, else the
		// previous build (so the alias keeps a real entry while the desired build
		// is mid-registration). An alias whose builds are all out of catalog
		// resolves to nothing and must not be advertised (it would 503).
		members := make([]string, 0, 2)
		desiredInCatalog := false
		if _, ok := catalogByID[a.DesiredBuild]; ok {
			members = append(members, a.DesiredBuild)
			desiredInCatalog = true
		}
		previousInCatalog := false
		if a.PreviousBuild != "" {
			if _, ok := catalogByID[a.PreviousBuild]; ok {
				members = append(members, a.PreviousBuild)
				previousInCatalog = true
			}
		}
		var primary string
		switch {
		case desiredInCatalog:
			primary = a.DesiredBuild
		case previousInCatalog:
			primary = a.PreviousBuild
		default:
			// No in-catalog build backs this alias — don't advertise it.
			continue
		}

		routable, warm := 0, 0
		canAccept := false
		for _, b := range members {
			if cap, ok := capByModel[b]; ok {
				routable += cap.RoutableProviders
				warm += cap.WarmProviders
				canAccept = canAccept || cap.CanAccept
			}
		}

		cm := catalogByID[primary]
		reg, hasReg := registryByID[primary]
		displayName := a.DisplayName
		if displayName == "" {
			displayName = cm.DisplayName
		}
		metadata := types.ModelMetadata{
			ModelType:         cm.ModelType,
			Quantization:      "", // an alias spans quants; omit the per-build quant
			DisplayName:       displayName,
			RoutableProviders: routable,
			WarmProviders:     warm,
			CanAccept:         canAccept,
		}
		entry := types.ModelEntry{
			ID:            a.AliasID,
			Object:        "model",
			OwnedBy:       "eigeninference",
			Name:          displayName,
			HuggingFaceID: huggingFaceIDForModel(primary, reg.Metadata),
			Metadata:      metadata,
		}
		// Pricing / context / features come from the primary build's registry
		// entry. Quantization is intentionally left blank on the alias.
		primaryQuant := ""
		if hasReg {
			primaryQuant = reg.Quantization
		}
		s.openRouterModelFieldsFor(primary, primaryQuant, reg, hasReg).applyToModelEntry(&entry)
		entry.Quantization = ""
		var caps []string
		if hasReg {
			caps = reg.Capabilities
		}
		entry.InputModalities, entry.OutputModalities = deriveModalities(cm.ModelType, caps)
		entries = append(entries, entry)
	}

	return entries, hidden, nil
}
