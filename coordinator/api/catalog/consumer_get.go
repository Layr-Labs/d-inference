package catalog

import (
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/api/types"
)

// GetModel handles GET /v1/models/{id...} — the OpenAI "retrieve model"
// endpoint. Model IDs may contain slashes (HuggingFace paths), hence the
// wildcard path segment. Hidden quant builds and marketplace-only OpenRouter
// aliases remain retrievable by exact id for inference-client parity.
func (s *Controller) GetModel(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	// Self-route requests retrieve from their owned live models (mirrors
	// ListModels, including the header-based opt-in): list and retrieve
	// must agree, or an OpenAI client that validates a model id via
	// retrieve-model can never use a listed local model.
	if policy := s.selfRoute(r); policy.enabled {
		entries := filterEntriesByKeyAllowList(s.OwnedModelEntries(policy.ownerAccountID, true), requestcontext.APIKey(r.Context()))
		for _, entry := range entries {
			if entry.ID == id {
				httpresponse.WriteJSON(w, http.StatusOK, entry)
				return
			}
		}
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("model_not_found",
			fmt.Sprintf("model %q not found", id), httpresponse.WithParam("model")))
		return
	}
	// Shares the memoized public catalog with GET /v1/models; the per-id scan
	// and the alias fallback below stay uncached.
	data, err := s.Entries(true)
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to list models"))
		return
	}
	for _, entry := range data {
		if entry.ID == id {
			httpresponse.WriteJSON(w, http.StatusOK, entry)
			return
		}
	}
	alias, found, aliasErr := s.store().GetModelAlias(id)
	if aliasErr != nil {
		s.logger.Error("model registry: failed to retrieve model alias", "model", id, "error", aliasErr)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to retrieve model"))
		return
	}
	if found && alias.Active && alias.OpenRouterOnly {
		var sourceEntry types.ModelEntry
		sourceFound := false
		for _, entry := range data {
			if entry.ID == alias.SourceModel {
				sourceEntry = entry
				sourceFound = true
				break
			}
		}
		if !sourceFound && AliasUsesConcreteSource(*alias) {
			catalogByID, registryByID, catalogErr := s.activeCatalogLookups()
			if catalogErr != nil {
				s.logger.Error("model registry: failed to retrieve concrete alias source", "model", id, "source_model", alias.SourceModel, "error", catalogErr)
				httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to retrieve model"))
				return
			}
			sourceEntry, sourceFound = s.modelEntryForCatalogConcrete(alias.SourceModel, catalogByID, registryByID)
		}
		if sourceFound {
			sourceEntry.ID = alias.AliasID
			sourceEntry.HuggingFaceID = alias.HuggingFaceID
			httpresponse.WriteJSON(w, http.StatusOK, sourceEntry)
			return
		}
	}
	httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("model_not_found",
		fmt.Sprintf("model %q not found", id), httpresponse.WithParam("model")))
}
