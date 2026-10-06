package aliaspolicy

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
	modelmeta "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/metadata"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func HideAliasBuild(hidden map[string]struct{}, catalogByID map[string]store.SupportedModel, buildID string) {
	if buildID == "" {
		return
	}
	if _, inCatalog := catalogByID[buildID]; inCatalog {
		hidden[buildID] = struct{}{}
	}
}

// aliasEntries projects rollout lineage into visible aliases and hidden builds.
func AliasEntries(aliases []store.ModelAlias, capByModel map[string]*registry.ModelCapacity, catalogByID map[string]store.SupportedModel, registryByID map[string]store.ModelRegistryEntry, enrich func(*types.ModelEntry, string, string, store.ModelRegistryEntry, bool)) ([]types.ModelEntry, map[string]struct{}) {
	hidden := make(map[string]struct{})
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
		HideAliasBuild(hidden, catalogByID, a.DesiredBuild)
		HideAliasBuild(hidden, catalogByID, a.PreviousBuild)
		for _, b := range a.RetiredBuilds {
			HideAliasBuild(hidden, catalogByID, b)
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
			HuggingFaceID: modelmeta.HuggingFaceIDForModel(primary, reg.Metadata),
			Metadata:      metadata,
		}
		// Pricing / context / features come from the primary build's registry
		// entry. Quantization is intentionally left blank on the alias.
		primaryQuant := ""
		if hasReg {
			primaryQuant = reg.Quantization
		}
		enrich(&entry, primary, primaryQuant, reg, hasReg)
		entry.Quantization = ""
		var caps []string
		if hasReg {
			caps = reg.Capabilities
		}
		entry.InputModalities, entry.OutputModalities = modelmeta.DeriveModalities(cm.ModelType, caps)
		entries = append(entries, entry)
	}

	return entries, hidden
}
