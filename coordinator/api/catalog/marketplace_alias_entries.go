package catalog

import (
	"sort"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// openRouterAliasEntries builds the OpenRouter feed entries for public model
// aliases and the set of member build ids to hide from the raw listing —
// mirroring aliasModelEntries on /v1/models. The entry's identity (id, slug)
// is the ALIAS so the marketplace listing is stable across build migrations;
// per-build fields (pricing, context, readiness) come from the alias's primary
// build (the desired build when in catalog, else the previous build).
// HuggingFaceID stays the primary build's configured HF path — OpenRouter
// ingests it for model metadata, and a fabricated path would break that; the
// routing name consumers send/receive is still only ever the alias.
func (s *Controller) openRouterAliasEntries(
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
	aggTypeByID map[string]string,
) ([]types.OpenRouterModel, map[string]struct{}, error) {
	hidden := make(map[string]struct{})
	aliases, err := s.store().ListModelAliases()
	if err != nil {
		return nil, nil, err
	}
	sort.Slice(aliases, func(i, j int) bool { return aliases[i].AliasID < aliases[j].AliasID })

	entries := make([]types.OpenRouterModel, 0, len(aliases))
	standardEntries := make(map[string]types.OpenRouterModel, len(aliases))
	openRouterAliases := make([]store.ModelAlias, 0)
	for _, a := range aliases {
		if !a.Active {
			continue
		}
		if a.OpenRouterOnly {
			openRouterAliases = append(openRouterAliases, a)
			continue
		}
		if a.DesiredBuild == "" {
			continue
		}
		// Never sell a raw build behind a public alias: hide EVERY build the
		// alias references — desired, previous, AND the retired lineage — from
		// the marketplace feed, even if the alias itself isn't listable right now.
		hideAliasBuild(hidden, catalogByID, a.DesiredBuild)
		hideAliasBuild(hidden, catalogByID, a.PreviousBuild)
		for _, b := range a.RetiredBuilds {
			hideAliasBuild(hidden, catalogByID, b)
		}
		members := make([]string, 0, 2)
		if _, ok := catalogByID[a.DesiredBuild]; ok {
			members = append(members, a.DesiredBuild)
		}
		if a.PreviousBuild != "" {
			if _, ok := catalogByID[a.PreviousBuild]; ok {
				members = append(members, a.PreviousBuild)
			}
		}
		if len(members) == 0 {
			continue
		}
		primary := members[0]

		cm := catalogByID[primary]
		modelType := cm.ModelType
		if at, ok := aggTypeByID[primary]; ok {
			modelType = at
		}
		if isNonTextModelType(modelType) {
			continue
		}

		reg, hasReg := registryByID[primary]
		var capabilities []string
		if hasReg {
			capabilities = reg.Capabilities
		}
		inputModalities, outputModalities := deriveModalities(modelType, capabilities)
		displayName := a.DisplayName
		if displayName == "" {
			displayName = openRouterModelName(cm, reg, hasReg, a.AliasID)
		}
		entry := types.OpenRouterModel{
			ID:                a.AliasID,
			HuggingFaceID:     huggingFaceIDForModel(primary, reg.Metadata),
			Name:              displayName,
			InputModalities:   inputModalities,
			OutputModalities:  outputModalities,
			SupportedFeatures: []string{},
			IsReady:           true,
		}
		s.openRouterModelFieldsFor(primary, "", reg, hasReg).applyToFeed(&entry)
		if hasReg {
			entry.IsReady = openRouterIsReady(reg.Metadata)
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(a.AliasID, reg.Metadata)}
		} else {
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(a.AliasID, nil)}
		}
		entry.Datacenters = s.aliasDatacenters(members)
		entries = append(entries, entry)
		standardEntries[a.AliasID] = entry
	}

	// OpenRouter-only aliases clone the complete source entry, then replace only
	// the three configured identities. Persisted source kind prevents a later
	// standard-alias mutation from changing concrete-source routing or feeds.
	for _, a := range openRouterAliases {
		var source types.OpenRouterModel
		var ok bool
		if AliasUsesConcreteSource(a) {
			source, ok = s.openRouterEntryForConcrete(a.SourceModel, catalogByID, registryByID, aggTypeByID)
		} else {
			source, ok = standardEntries[a.SourceModel]
		}
		if !ok || a.OpenRouterSlug == "" || a.HuggingFaceID == "" {
			s.logger.Warn("OpenRouter alias source or identities unavailable", "alias_id", a.AliasID, "source_model", a.SourceModel)
			continue
		}
		clone := source
		clone.ID = a.AliasID
		clone.HuggingFaceID = a.HuggingFaceID
		clone.OpenRouter = &types.OpenRouterSlug{Slug: a.OpenRouterSlug}
		entries = append(entries, clone)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].ID < entries[j].ID })
	return entries, hidden, nil
}

// aliasDatacenters unions the datacenter country codes across an alias's member
// builds (providers may be mid-migration, serving either build).
func (s *Controller) aliasDatacenters(members []string) []types.OpenRouterDatacenter {
	seen := make(map[string]struct{})
	var dcs []types.OpenRouterDatacenter
	for _, m := range members {
		for _, dc := range s.modelDatacenters(m) {
			if _, dup := seen[dc.CountryCode]; dup {
				continue
			}
			seen[dc.CountryCode] = struct{}{}
			dcs = append(dcs, dc)
		}
	}
	return dcs
}
