package api

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// aliasBuildRequest is one build attachment in an alias upsert request.
type aliasBuildRequest struct {
	BuildID string `json:"build_id"`
	Weight  int    `json:"weight"`
	Active  *bool  `json:"active"` // pointer so omission defaults to true
}

// aliasUpsertRequest is the body for POST /v1/admin/models/aliases.
type aliasUpsertRequest struct {
	AliasID     string              `json:"alias_id"`
	DisplayName string              `json:"display_name"`
	Builds      []aliasBuildRequest `json:"builds"`
	Active      *bool               `json:"active"` // pointer so omission defaults to true
}

// handleModelAliasUpsert creates or replaces a public model alias (idempotent on
// alias_id) and re-syncs the registry so the new mapping takes effect
// immediately. POST /v1/admin/models/aliases.
func (s *Server) handleModelAliasUpsert(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}

	var req aliasUpsertRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	req.AliasID = strings.TrimSpace(req.AliasID)
	if req.AliasID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "alias_id is required", withParam("alias_id")))
		return
	}
	if len(req.Builds) == 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "at least one build is required", withParam("builds")))
		return
	}
	// Namespace guard: an alias id must not collide with a concrete model id,
	// otherwise resolution and routing become ambiguous.
	if rec, err := s.store.GetModelRegistryRecord(req.AliasID); err == nil && rec != nil {
		writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error",
			"alias_id collides with an existing model id", withParam("alias_id")))
		return
	}

	builds := make([]store.ModelAliasBuild, 0, len(req.Builds))
	seen := make(map[string]bool, len(req.Builds))
	for _, b := range req.Builds {
		b.BuildID = strings.TrimSpace(b.BuildID)
		if b.BuildID == "" {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "build_id is required for every build", withParam("builds")))
			return
		}
		if seen[b.BuildID] {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"duplicate build_id "+b.BuildID+" in alias", withParam("builds")))
			return
		}
		seen[b.BuildID] = true
		if b.BuildID == req.AliasID {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "an alias cannot reference itself", withParam("builds")))
			return
		}
		if b.Weight < 0 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "weight must be >= 0", withParam("builds")))
			return
		}
		// The build must be a registered model so we never alias to a phantom id.
		rec, err := s.store.GetModelRegistryRecord(b.BuildID)
		if err != nil || rec == nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"build_id "+b.BuildID+" is not a registered model", withParam("builds")))
			return
		}
		active := true
		if b.Active != nil {
			active = *b.Active
		}
		builds = append(builds, store.ModelAliasBuild{BuildID: b.BuildID, Weight: b.Weight, Active: active})
	}

	active := true
	if req.Active != nil {
		active = *req.Active
	}
	alias := &store.ModelAlias{
		AliasID:     req.AliasID,
		DisplayName: req.DisplayName,
		Builds:      builds,
		Active:      active,
	}
	if err := s.store.UpsertModelAlias(alias); err != nil {
		s.logger.Error("upsert model alias failed", "alias_id", req.AliasID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save alias"))
		return
	}
	s.SyncModelCatalog()

	saved, _, _ := s.store.GetModelAlias(req.AliasID)
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "alias": saved})
}

// handleModelAliasList returns every configured alias. GET /v1/admin/models/aliases.
func (s *Server) handleModelAliasList(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list aliases"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"aliases": aliases})
}

// handleModelAliasDelete removes an alias. DELETE /v1/admin/models/aliases/{aliasID}.
func (s *Server) handleModelAliasDelete(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliasID := strings.TrimSpace(r.PathValue("aliasID"))
	if aliasID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "alias id is required"))
		return
	}
	// Serialize the delete with the migration controller tick. The tick re-reads
	// the active migration under migrationMu and then calls applyWeights (which
	// re-upserts the alias); without this lock, a delete landing between that
	// re-read and applyWeights would be silently resurrected by the tick
	// recreating the alias. Same lock the pause/resume/rollback handlers hold.
	s.migrationMu.Lock()
	defer s.migrationMu.Unlock()
	if err := s.store.DeleteModelAlias(aliasID); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to delete alias"))
		return
	}
	// Also drop any migration for this alias — otherwise the controller would
	// keep ticking and applyWeights would recreate the alias we just deleted.
	if err := s.store.DeleteModelMigration(aliasID); err != nil {
		s.logger.Warn("alias deleted but migration cleanup failed", "alias", aliasID, "error", err)
	}
	s.SyncModelCatalog()
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted", "alias_id": aliasID})
}
