package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/registry"

	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// handleListModels handles GET /v1/models.
//
// Returns a deduplicated list of models across all connected providers,
// including attestation metadata (trust level, Secure Enclave status,
// provider count) for each model. Capacity fields (routable_providers,
// warm_providers, can_accept) are included from the live capacity snapshot.
func (s *Server) handleListModels(w http.ResponseWriter, r *http.Request) {
	models := s.registry.ListModels()

	// Build a lookup of capacity data keyed by model ID.
	capacities := s.registry.ModelCapacitySnapshot()
	capByModel := make(map[string]*registry.ModelCapacity, len(capacities))
	for i := range capacities {
		capByModel[capacities[i].ModelID] = &capacities[i]
	}

	// Filter to only show models from the active catalog, and capture the richer
	// registry entries used to populate the OpenRouter provider fields. These
	// lookups are shared with the dedicated /v1/models/openrouter feed.
	catalogByID, registryByID, err := s.activeCatalogLookups()
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list models"))
		return
	}

	data := make([]types.ModelEntry, 0, len(models))
	for _, m := range models {
		cm, inCatalog := catalogByID[m.ID]
		if len(catalogByID) > 0 && !inCatalog {
			continue
		}
		metadata := types.ModelMetadata{
			ModelType:         m.ModelType,
			Quantization:      m.Quantization,
			ProviderCount:     m.Providers,
			AttestedProviders: m.AttestedProviders,
			TrustLevel:        string(m.TrustLevel),
		}
		// Add capacity fields from live snapshot.
		if cap, ok := capByModel[m.ID]; ok {
			metadata.RoutableProviders = cap.RoutableProviders
			metadata.WarmProviders = cap.WarmProviders
			metadata.CanAccept = cap.CanAccept
		} else {
			metadata.RoutableProviders = 0
			metadata.WarmProviders = 0
			metadata.CanAccept = false
		}
		if m.Attestation != nil {
			metadata.Attestation = &types.ModelAttestation{
				SecureEnclave: m.Attestation.SecureEnclave,
				SIPEnabled:    m.Attestation.SIPEnabled,
				SecureBoot:    m.Attestation.SecureBoot,
			}
		}
		if inCatalog && cm.DisplayName != "" {
			metadata.DisplayName = cm.DisplayName
		}

		entry := types.ModelEntry{
			ID:            m.ID,
			Object:        "model",
			Created:       0,
			OwnedBy:       "eigeninference",
			Name:          metadata.DisplayName,
			HuggingFaceID: m.ID, // model IDs are HuggingFace paths
			Metadata:      metadata,
		}

		// OpenRouter provider fields (quantization, per-token pricing, sampling
		// params, and registry-sourced metadata), shared with the dedicated
		// /v1/models/openrouter feed.
		reg, hasReg := registryByID[m.ID]
		s.openRouterModelFieldsFor(m.ID, m.Quantization, reg, hasReg).applyToModelEntry(&entry)

		// Modalities are derived from the model's capabilities (text by default).
		var caps []string
		if hasReg {
			caps = reg.Capabilities
		}
		entry.InputModalities, entry.OutputModalities = deriveModalities(m.ModelType, caps)

		data = append(data, entry)
	}

	writeJSON(w, http.StatusOK, types.ModelListResponse{
		Object: "list",
		Data:   data,
	})
}
