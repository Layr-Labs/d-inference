package catalog

import (
	"encoding/json"
	"net/http"
	"strings"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	aliaspolicy "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/aliaspolicy"
	registration "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/registration"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// openRouterAliasUpsertRequest configures one OpenRouter-only clone of an
// existing standard alias or concrete catalog model. OpenRouter sends ID to the
// inference API; SourceModel supplies every non-identity feed field and routing.
type openRouterAliasUpsertRequest struct {
	ID             string `json:"id"`
	SourceModel    string `json:"source_model"`
	OpenRouterSlug string `json:"openrouter_slug"`
	HuggingFaceID  string `json:"hugging_face_id"`
	Active         *bool  `json:"active"`
}

// HandleOpenRouterAliasUpsert creates or replaces an OpenRouter-only alias.
// POST /v1/admin/models/openrouter-aliases.
func (s *Owner) HandleOpenRouterAliasUpsert(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.access.RequirePublishingAPIKey(w, r); !ok {
		return
	}

	var req openRouterAliasUpsertRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	req.ID = strings.TrimSpace(req.ID)
	req.SourceModel = strings.TrimSpace(req.SourceModel)
	req.OpenRouterSlug = strings.TrimSpace(req.OpenRouterSlug)
	req.HuggingFaceID = strings.TrimSpace(req.HuggingFaceID)

	switch {
	case req.ID == "":
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "id is required", httpx.WithParam("id")))
		return
	case len(req.ID) > maxAliasIDLength || !registration.ValidRegistryIdentifier(req.ID, false):
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "id may only contain letters, digits, '.', '_' and '-' (max 128 chars)", httpx.WithParam("id")))
		return
	case req.SourceModel == "":
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "source_model is required", httpx.WithParam("source_model")))
		return
	case req.SourceModel == req.ID:
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "source_model cannot equal id", httpx.WithParam("source_model")))
		return
	case req.OpenRouterSlug == "":
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "openrouter_slug is required", httpx.WithParam("openrouter_slug")))
		return
	case req.HuggingFaceID == "":
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "hugging_face_id is required", httpx.WithParam("hugging_face_id")))
		return
	}
	s.modelAliasMutationMu.Lock()
	defer s.modelAliasMutationMu.Unlock()

	sourceKind := store.ModelAliasSourceAlias
	source, found, err := s.store.GetModelAlias(req.SourceModel)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to get source model"))
		return
	}
	sourceAvailable := found && !source.OpenRouterOnly && source.Active && source.DesiredBuild != ""
	if !sourceAvailable {
		sourceKind = store.ModelAliasSourceConcrete
		catalogByID, _, catalogErr := s.activeCatalogLookups()
		if catalogErr != nil {
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to get source model"))
			return
		}
		_, concreteFound := catalogByID[req.SourceModel]
		if concreteFound && !aliaspolicy.ConcreteModelEligibleForOpenRouterFeed(req.SourceModel, catalogByID, s.openRouterAggregateTypeByID()) {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "concrete source_model is not eligible for the OpenRouter text feed", httpx.WithParam("source_model")))
			return
		}
		sourceAvailable = concreteFound
		if sourceAvailable {
			aliases, listErr := s.store.ListModelAliases()
			if listErr != nil {
				httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to validate source model"))
				return
			}
			if coveringAlias, covered := aliaspolicy.StandardAliasCoveringBuild(aliases, req.SourceModel); covered {
				httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", "concrete source_model is covered by standard alias "+coveringAlias+"; use that alias as source_model", httpx.WithParam("source_model")))
				return
			}
		}
	}
	if !sourceAvailable {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "source_model must be an active standard alias or concrete catalog model", httpx.WithParam("source_model")))
		return
	}
	if rec, _ := s.store.GetModelRegistryRecord(req.ID); rec != nil {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", "id collides with an existing model id", httpx.WithParam("id")))
		return
	}
	if existing, exists, err := s.store.GetModelAlias(req.ID); err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to get alias"))
		return
	} else if exists && !existing.OpenRouterOnly {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", "id collides with an existing standard alias", httpx.WithParam("id")))
		return
	}

	active := true
	if req.Active != nil {
		active = *req.Active
	}
	alias := &store.ModelAlias{
		AliasID:        req.ID,
		OpenRouterOnly: true,
		SourceModel:    req.SourceModel,
		SourceKind:     sourceKind,
		OpenRouterSlug: req.OpenRouterSlug,
		HuggingFaceID:  req.HuggingFaceID,
		Active:         active,
	}
	if err := s.store.UpsertModelAlias(alias); err != nil {
		s.logger.Error("upsert OpenRouter alias failed", "alias_id", req.ID, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to save OpenRouter alias"))
		return
	}
	s.SyncModelCatalog()

	saved, _, _ := s.store.GetModelAlias(req.ID)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": "ok", "alias": saved})
}

// HandleOpenRouterAliasList lists only OpenRouter feed aliases.
// GET /v1/admin/models/openrouter-aliases.
func (s *Owner) HandleOpenRouterAliasList(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.access.RequirePublishingAPIKey(w, r); !ok {
		return
	}
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to list OpenRouter aliases"))
		return
	}
	out := aliases[:0]
	for _, alias := range aliases {
		if alias.OpenRouterOnly {
			out = append(out, alias)
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"aliases": out})
}

// HandleOpenRouterAliasDelete removes one OpenRouter feed alias.
// DELETE /v1/admin/models/openrouter-aliases/{aliasID}.
func (s *Owner) HandleOpenRouterAliasDelete(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.access.RequirePublishingAPIKey(w, r); !ok {
		return
	}
	aliasID := strings.TrimSpace(r.PathValue("aliasID"))
	if aliasID == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "alias id is required"))
		return
	}
	alias, found, err := s.store.GetModelAlias(aliasID)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to get OpenRouter alias"))
		return
	}
	if !found || !alias.OpenRouterOnly {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("invalid_request_error", "OpenRouter alias not found"))
		return
	}
	if err := s.store.DeleteModelAlias(aliasID); err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to delete OpenRouter alias"))
		return
	}
	s.SyncModelCatalog()
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": "deleted", "id": aliasID})
}
