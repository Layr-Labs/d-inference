package api

import (
	"net/http"
	"sort"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleListModelsOpenRouter handles GET /v1/models/openrouter.
//
// It emits the pure OpenRouter provider "List Models" schema (no Darkbloom
// metadata block) for the models we want OpenRouter to sell.
//
// The feed is driven by the active CATALOG, not by live provider availability:
// a registered model stays listed even when no provider is momentarily
// online/warm for it. That matches OpenRouter's model, where transient capacity
// is handled by 429s and launch state by the is_ready flag — a provider restart
// must not make the model vanish from the marketplace. Live provider data is
// used only as supplemental signal (datacenters, and excluding a model whose
// providers report a non-text aggregate type).
func (s *Server) handleListModelsOpenRouter(w http.ResponseWriter, r *http.Request) {
	catalogByID, registryByID, err := s.activeCatalogLookups()
	if err != nil {
		s.logger.Error("openrouter models: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}

	// Provider-reported model types override the catalog's text fallback so
	// known non-text models never enter the OpenRouter provider feed.
	aggTypeByID := s.openRouterAggregateTypeByID()

	// Public aliases get the same treatment as /v1/models: the alias is the
	// purchasable entry and its member builds are hidden, so the marketplace
	// never lists a raw quant build that a migration will later retire (a
	// retired build would otherwise stay listed and black-hole requests).
	aliasEntries, hiddenBuilds := s.openRouterAliasEntries(catalogByID, registryByID, aggTypeByID)

	// Stable output order.
	ids := make([]string, 0, len(catalogByID))
	for id := range catalogByID {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	data := make([]types.OpenRouterModel, 0, len(ids)+len(aliasEntries))
	data = append(data, aliasEntries...)
	for _, id := range ids {
		if _, hidden := hiddenBuilds[id]; hidden {
			continue
		}
		entry, ok := s.openRouterEntryForConcrete(id, catalogByID, registryByID, aggTypeByID)
		if !ok {
			continue
		}
		data = append(data, entry)
	}

	writeJSON(w, http.StatusOK, types.OpenRouterModelsResponse{Data: data})
}

// openRouterAliasEntries builds the OpenRouter feed entries for public model
// aliases and the set of member build ids to hide from the raw listing —
// mirroring aliasModelEntries on /v1/models. The entry's identity (id, slug)
// is the ALIAS so the marketplace listing is stable across build migrations;
// per-build fields (pricing, context, readiness) come from the alias's primary
// build (the desired build when in catalog, else the previous build).
// HuggingFaceID stays the primary build's configured HF path — OpenRouter
// ingests it for model metadata, and a fabricated path would break that; the
// routing name consumers send/receive is still only ever the alias.
func (s *Server) openRouterAliasEntries(
	catalogByID map[string]store.SupportedModel,
	registryByID map[string]store.ModelRegistryEntry,
	aggTypeByID map[string]string,
) ([]types.OpenRouterModel, map[string]struct{}) {
	hidden := make(map[string]struct{})
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		s.logger.Error("openrouter models: failed to list aliases", "error", err)
		return nil, hidden
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
		if openRouterAliasUsesConcreteSource(a) {
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
	return entries, hidden
}

// aliasDatacenters unions the datacenter country codes across an alias's member
// builds (providers may be mid-migration, serving either build).
func (s *Server) aliasDatacenters(members []string) []types.OpenRouterDatacenter {
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

// openRouterModelName resolves the feed display name for a model: the catalog
// display name, then the registry display name, then the model ID as a last
// resort.
func openRouterModelName(cm store.SupportedModel, reg store.ModelRegistryEntry, hasReg bool, modelID string) string {
	if cm.DisplayName != "" {
		return cm.DisplayName
	}
	if hasReg && reg.DisplayName != "" {
		return reg.DisplayName
	}
	return modelID
}

// modelDatacenters maps the country codes of providers serving a model into the
// OpenRouter "datacenters" shape, returning nil when none are known so the
// omitempty field is omitted.
func (s *Server) modelDatacenters(modelID string) []types.OpenRouterDatacenter {
	ccs := s.registry.ModelCountryCodes(modelID)
	if len(ccs) == 0 {
		return nil
	}
	dcs := make([]types.OpenRouterDatacenter, 0, len(ccs))
	for _, cc := range ccs {
		dcs = append(dcs, types.OpenRouterDatacenter{CountryCode: cc})
	}
	return dcs
}
