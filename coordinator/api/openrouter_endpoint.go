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

	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("openrouter models: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}
	catalogByID := make(map[string]store.SupportedModel, len(registryRows))
	registryByID := make(map[string]store.ModelRegistryEntry, len(registryRows))
	if len(registryRows) > 0 {
		for _, row := range registryRows {
			cm := supportedModelFromRegistryRecord(&row)
			if cm.Active {
				catalogByID[cm.ID] = cm
				registryByID[cm.ID] = row.ModelRegistryEntry
			}
		}
	} else {
		for _, cm := range s.store.ListSupportedModels() {
			if cm.Active && !IsRetiredProviderModel(cm) {
				catalogByID[cm.ID] = cm
			}
		}
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

		name := cm.DisplayName
		if name == "" && hasReg {
			name = reg.DisplayName
		}
		if name == "" {
			name = m.ID
		}

		inPM, outPM := s.resolvePlatformPricing(m.ID)
		entry := types.OpenRouterModel{
			ID:                          m.ID,
			HuggingFaceID:               m.ID, // our model IDs are HuggingFace paths
			Name:                        name,
			InputModalities:             []string{"text"},
			OutputModalities:            []string{"text"},
			Quantization:                mapQuantizationToOpenRouter(m.Quantization),
			Pricing:                     *buildModelPricing(inPM, outPM),
			SupportedSamplingParameters: defaultSamplingParameters(),
			SupportedFeatures:           []string{},
			IsReady:                     true,
		}

		if hasReg {
			if !reg.CreatedAt.IsZero() {
				entry.Created = reg.CreatedAt.Unix()
			}
			entry.Description = reg.Description
			entry.ContextLength = reg.MaxContextLength
			entry.MaxOutputLength = reg.MaxOutputLength
			if f := supportedFeaturesFromCapabilities(reg.Capabilities); len(f) > 0 {
				entry.SupportedFeatures = f
			}
			if dd, ok := reg.Metadata["deprecation_date"].(string); ok && dd != "" {
				entry.DeprecationDate = dd
			}
			entry.IsReady = openRouterIsReady(reg.Metadata)
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(m.ID, reg.Metadata)}
		} else {
			entry.OpenRouter = &types.OpenRouterSlug{Slug: openRouterSlug(m.ID, nil)}
		}

		// Datacenters from the country codes of providers serving this model.
		if ccs := s.registry.ModelCountryCodes(m.ID); len(ccs) > 0 {
			entry.Datacenters = make([]types.OpenRouterDatacenter, 0, len(ccs))
			for _, cc := range ccs {
				entry.Datacenters = append(entry.Datacenters, types.OpenRouterDatacenter{CountryCode: cc})
			}
		}

		data = append(data, entry)
	}

	writeJSON(w, http.StatusOK, types.OpenRouterModelsResponse{Data: data})
}
