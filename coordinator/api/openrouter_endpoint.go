package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleListModelsOpenRouter handles GET /v1/models/openrouter.
//
// It emits the pure OpenRouter provider "List Models" schema (no Darkbloom
// metadata block) for the models we want OpenRouter to sell. It reuses the same
// field-mapping helpers as /v1/models but applies OpenRouter-specific rules:
// text-only modalities, staging-based is_ready, marketplace slug, and a
// text-only model filter. Required fields are always present.
func (s *Server) handleListModelsOpenRouter(w http.ResponseWriter, r *http.Request) {
	models := s.registry.ListModels()

	catalogByID, registryByID, err := s.activeCatalogLookups()
	if err != nil {
		s.logger.Error("openrouter models: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}

	data := make([]types.OpenRouterModel, 0, len(models))
	for _, m := range models {
		cm, inCatalog := catalogByID[m.ID]
		if len(catalogByID) > 0 && !inCatalog {
			continue
		}
		// Text-only feed for now: exclude embedding/tts/image/audio models.
		if inCatalog && !isTextModelType(cm.ModelType) {
			continue
		}

		reg, hasReg := registryByID[m.ID]
		entry := types.OpenRouterModel{
			ID:                m.ID,
			HuggingFaceID:     m.ID, // our model IDs are HuggingFace paths
			Name:              openRouterModelName(cm, reg, hasReg, m.ID),
			InputModalities:   []string{"text"},
			OutputModalities:  []string{"text"},
			SupportedFeatures: []string{},
			IsReady:           true,
		}
		s.openRouterModelFieldsFor(m, reg, hasReg).applyToFeed(&entry)

		// is_ready is a launch/staging flag and the slug is per-model; both
		// come from registry metadata (defaults apply for legacy rows).
		if hasReg {
			entry.IsReady = openRouterIsReady(reg.Metadata)
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(m.ID, reg.Metadata)}
		} else {
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(m.ID, nil)}
		}
		entry.Datacenters = s.modelDatacenters(m.ID)

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
