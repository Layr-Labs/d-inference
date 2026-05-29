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

	// Provider-reported model types (when any provider is online) let us
	// exclude non-text models even though the registry currently stores every
	// model as "text".
	aggTypeByID := make(map[string]string)
	for _, m := range s.registry.ListModels() {
		if m.ModelType != "" {
			aggTypeByID[m.ID] = m.ModelType
		}
	}

	// Stable output order.
	ids := make([]string, 0, len(catalogByID))
	for id := range catalogByID {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	data := make([]types.OpenRouterModel, 0, len(ids))
	for _, id := range ids {
		cm := catalogByID[id]
		// Text-only feed: prefer the provider-reported type, fall back to the
		// catalog type. Excludes only known non-text modalities
		// (embedding/tts/image/audio/rerank); text/chat/unknown stay listed.
		modelType := cm.ModelType
		if at, ok := aggTypeByID[id]; ok {
			modelType = at
		}
		if isNonTextModelType(modelType) {
			continue
		}

		reg, hasReg := registryByID[id]
		entry := types.OpenRouterModel{
			ID:                id,
			HuggingFaceID:     id, // our model IDs are HuggingFace paths
			Name:              openRouterModelName(cm, reg, hasReg, id),
			InputModalities:   []string{"text"},
			OutputModalities:  []string{"text"},
			SupportedFeatures: []string{},
			IsReady:           true,
		}
		// Quantization comes from the registry entry (the catalog row carries
		// none); legacy rows simply omit it.
		s.openRouterModelFieldsFor(id, reg.Quantization, reg, hasReg).applyToFeed(&entry)

		// is_ready is a launch/staging flag and the slug is per-model; both
		// come from registry metadata (defaults apply for legacy rows).
		if hasReg {
			entry.IsReady = openRouterIsReady(reg.Metadata)
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(id, reg.Metadata)}
		} else {
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(id, nil)}
		}
		entry.Datacenters = s.modelDatacenters(id)

		data = append(data, entry)
	}

	writeJSON(w, http.StatusOK, types.OpenRouterModelsResponse{Data: data})
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
