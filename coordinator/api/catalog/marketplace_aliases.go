package catalog

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
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

// UpsertOpenRouterAlias creates or replaces an OpenRouter-only alias.
// POST /v1/admin/models/openrouter-aliases.
func (s *Controller) UpsertOpenRouterAlias(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}

	var req openRouterAliasUpsertRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	req.ID = strings.TrimSpace(req.ID)
	req.SourceModel = strings.TrimSpace(req.SourceModel)
	req.OpenRouterSlug = strings.TrimSpace(req.OpenRouterSlug)
	req.HuggingFaceID = strings.TrimSpace(req.HuggingFaceID)

	switch {
	case req.ID == "":
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "id is required", httpresponse.WithParam("id")))
		return
	case len(req.ID) > maxAliasIDLength || !validRegistryIdentifier(req.ID, false):
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "id may only contain letters, digits, '.', '_' and '-' (max 128 chars)", httpresponse.WithParam("id")))
		return
	case req.SourceModel == "":
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "source_model is required", httpresponse.WithParam("source_model")))
		return
	case req.SourceModel == req.ID:
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "source_model cannot equal id", httpresponse.WithParam("source_model")))
		return
	case req.OpenRouterSlug == "":
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "openrouter_slug is required", httpresponse.WithParam("openrouter_slug")))
		return
	case req.HuggingFaceID == "":
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "hugging_face_id is required", httpresponse.WithParam("hugging_face_id")))
		return
	}
	s.modelAliasMutationMu.Lock()
	defer s.modelAliasMutationMu.Unlock()

	sourceKind := store.ModelAliasSourceAlias
	source, found, err := s.store().GetModelAlias(req.SourceModel)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to get source model"))
		return
	}
	sourceAvailable := found && !source.OpenRouterOnly && source.Active && source.DesiredBuild != ""
	if !sourceAvailable {
		sourceKind = store.ModelAliasSourceConcrete
		catalogByID, _, catalogErr := s.activeCatalogLookups()
		if catalogErr != nil {
			httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to get source model"))
			return
		}
		_, concreteFound := catalogByID[req.SourceModel]
		if concreteFound && !concreteModelEligibleForOpenRouterFeed(req.SourceModel, catalogByID, s.openRouterAggregateTypeByID()) {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "concrete source_model is not eligible for the OpenRouter text feed", httpresponse.WithParam("source_model")))
			return
		}
		sourceAvailable = concreteFound
		if sourceAvailable {
			aliases, listErr := s.store().ListModelAliases()
			if listErr != nil {
				httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to validate source model"))
				return
			}
			if coveringAlias, covered := standardAliasCoveringBuild(aliases, req.SourceModel); covered {
				httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("invalid_request_error", "concrete source_model is covered by standard alias "+coveringAlias+"; use that alias as source_model", httpresponse.WithParam("source_model")))
				return
			}
		}
	}
	if !sourceAvailable {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "source_model must be an active standard alias or concrete catalog model", httpresponse.WithParam("source_model")))
		return
	}
	if rec, err := s.store().GetModelRegistryRecord(req.ID); err != nil && !errors.Is(err, store.ErrNotFound) {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to check model namespace"))
		return
	} else if rec != nil {
		httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("invalid_request_error", "id collides with an existing model id", httpresponse.WithParam("id")))
		return
	}
	if existing, exists, err := s.store().GetModelAlias(req.ID); err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to get alias"))
		return
	} else if exists && !existing.OpenRouterOnly {
		httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("invalid_request_error", "id collides with an existing standard alias", httpresponse.WithParam("id")))
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
	if err := s.store().UpsertModelAlias(alias); err != nil {
		s.logger.Error("upsert OpenRouter alias failed", "alias_id", req.ID, "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to save OpenRouter alias"))
		return
	}
	s.syncCatalog()

	saved, _, _ := s.store().GetModelAlias(req.ID)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"status": "ok", "alias": saved})
}

// ListOpenRouterAliases lists only OpenRouter feed aliases.
// GET /v1/admin/models/openrouter-aliases.
func (s *Controller) ListOpenRouterAliases(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliases, err := s.store().ListModelAliases()
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to list OpenRouter aliases"))
		return
	}
	out := aliases[:0]
	for _, alias := range aliases {
		if alias.OpenRouterOnly {
			out = append(out, alias)
		}
	}
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"aliases": out})
}

// DeleteOpenRouterAlias removes one OpenRouter feed alias.
// DELETE /v1/admin/models/openrouter-aliases/{aliasID}.
func (s *Controller) DeleteOpenRouterAlias(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliasID := strings.TrimSpace(r.PathValue("aliasID"))
	if aliasID == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "alias id is required"))
		return
	}
	alias, found, err := s.store().GetModelAlias(aliasID)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to get OpenRouter alias"))
		return
	}
	if !found || !alias.OpenRouterOnly {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("invalid_request_error", "OpenRouter alias not found"))
		return
	}
	if err := s.store().DeleteModelAlias(aliasID); err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to delete OpenRouter alias"))
		return
	}
	s.syncCatalog()
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"status": "deleted", "id": aliasID})
}
