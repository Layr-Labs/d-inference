package api

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// openRouterAliasUpsertRequest configures one OpenRouter-only clone of an
// existing standard model alias. OpenRouter sends ID to the inference API;
// SourceModel supplies every non-identity feed field and the live routing target.
type openRouterAliasUpsertRequest struct {
	ID             string `json:"id"`
	SourceModel    string `json:"source_model"`
	OpenRouterSlug string `json:"openrouter_slug"`
	HuggingFaceID  string `json:"hugging_face_id"`
	Active         *bool  `json:"active"`
}

// handleOpenRouterAliasUpsert creates or replaces an OpenRouter-only alias.
// POST /v1/admin/models/openrouter-aliases.
func (s *Server) handleOpenRouterAliasUpsert(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}

	var req openRouterAliasUpsertRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	req.ID = strings.TrimSpace(req.ID)
	req.SourceModel = strings.TrimSpace(req.SourceModel)
	req.OpenRouterSlug = strings.TrimSpace(req.OpenRouterSlug)
	req.HuggingFaceID = strings.TrimSpace(req.HuggingFaceID)

	switch {
	case req.ID == "":
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "id is required", withParam("id")))
		return
	case len(req.ID) > maxAliasIDLength || !validRegistryIdentifier(req.ID, false):
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "id may only contain letters, digits, '.', '_' and '-' (max 128 chars)", withParam("id")))
		return
	case req.SourceModel == "":
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "source_model is required", withParam("source_model")))
		return
	case req.SourceModel == req.ID:
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "source_model cannot equal id", withParam("source_model")))
		return
	case req.OpenRouterSlug == "":
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "openrouter_slug is required", withParam("openrouter_slug")))
		return
	case req.HuggingFaceID == "":
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "hugging_face_id is required", withParam("hugging_face_id")))
		return
	}

	source, found, err := s.store.GetModelAlias(req.SourceModel)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to get source alias"))
		return
	}
	if !found || source.OpenRouterOnly || !source.Active || source.DesiredBuild == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "source_model must be an active standard model alias", withParam("source_model")))
		return
	}
	if rec, _ := s.store.GetModelRegistryRecord(req.ID); rec != nil {
		writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error", "id collides with an existing model id", withParam("id")))
		return
	}
	if existing, exists, err := s.store.GetModelAlias(req.ID); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to get alias"))
		return
	} else if exists && !existing.OpenRouterOnly {
		writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error", "id collides with an existing standard alias", withParam("id")))
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
		OpenRouterSlug: req.OpenRouterSlug,
		HuggingFaceID:  req.HuggingFaceID,
		Active:         active,
	}
	if err := s.store.UpsertModelAlias(alias); err != nil {
		s.logger.Error("upsert OpenRouter alias failed", "alias_id", req.ID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save OpenRouter alias"))
		return
	}
	s.SyncModelCatalog()

	saved, _, _ := s.store.GetModelAlias(req.ID)
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "alias": saved})
}

// handleOpenRouterAliasList lists only OpenRouter feed aliases.
// GET /v1/admin/models/openrouter-aliases.
func (s *Server) handleOpenRouterAliasList(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list OpenRouter aliases"))
		return
	}
	out := aliases[:0]
	for _, alias := range aliases {
		if alias.OpenRouterOnly {
			out = append(out, alias)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"aliases": out})
}

// handleOpenRouterAliasDelete removes one OpenRouter feed alias.
// DELETE /v1/admin/models/openrouter-aliases/{aliasID}.
func (s *Server) handleOpenRouterAliasDelete(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliasID := strings.TrimSpace(r.PathValue("aliasID"))
	if aliasID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "alias id is required"))
		return
	}
	alias, found, err := s.store.GetModelAlias(aliasID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to get OpenRouter alias"))
		return
	}
	if !found || !alias.OpenRouterOnly {
		writeJSON(w, http.StatusNotFound, errorResponse("invalid_request_error", "OpenRouter alias not found"))
		return
	}
	if err := s.store.DeleteModelAlias(aliasID); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to delete OpenRouter alias"))
		return
	}
	s.SyncModelCatalog()
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted", "id": aliasID})
}
