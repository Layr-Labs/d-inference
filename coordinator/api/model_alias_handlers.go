package api

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// aliasUpsertRequest is the body for POST /v1/admin/models/aliases. An alias is a
// stable public name resolving to a single desired build, with an optional
// still-acceptable previous build during a staggered rollout. A rollout is just
// setting desired_build; a revert is setting it back.
type aliasUpsertRequest struct {
	AliasID       string `json:"alias_id"`
	DisplayName   string `json:"display_name"`
	DesiredBuild  string `json:"desired_build"`
	PreviousBuild string `json:"previous_build"`
	Active        *bool  `json:"active"` // pointer so omission defaults to true
}

// handleModelAliasUpsert creates or replaces a public model alias (idempotent on
// alias_id) and re-syncs the registry so the new desired-build pointer takes
// effect immediately, then declaratively pushes desired_models to every
// connected provider already serving the alias. POST /v1/admin/models/aliases.
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
	req.DesiredBuild = strings.TrimSpace(req.DesiredBuild)
	req.PreviousBuild = strings.TrimSpace(req.PreviousBuild)
	if req.AliasID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "alias_id is required", withParam("alias_id")))
		return
	}
	if req.DesiredBuild == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "desired_build is required", withParam("desired_build")))
		return
	}
	// Namespace guard: an alias id must not collide with a concrete model id,
	// otherwise resolution and routing become ambiguous.
	if rec, err := s.store.GetModelRegistryRecord(req.AliasID); err == nil && rec != nil {
		writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error",
			"alias_id collides with an existing model id", withParam("alias_id")))
		return
	}
	if req.DesiredBuild == req.AliasID || req.PreviousBuild == req.AliasID {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "an alias cannot reference itself", withParam("desired_build")))
		return
	}
	if req.PreviousBuild != "" && req.PreviousBuild == req.DesiredBuild {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "previous_build must differ from desired_build", withParam("previous_build")))
		return
	}
	// Both builds must be registered models so we never alias to a phantom id.
	if rec, err := s.store.GetModelRegistryRecord(req.DesiredBuild); err != nil || rec == nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"desired_build "+req.DesiredBuild+" is not a registered model", withParam("desired_build")))
		return
	}
	if req.PreviousBuild != "" {
		if rec, err := s.store.GetModelRegistryRecord(req.PreviousBuild); err != nil || rec == nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"previous_build "+req.PreviousBuild+" is not a registered model", withParam("previous_build")))
			return
		}
	}

	active := true
	if req.Active != nil {
		active = *req.Active
	}
	alias := &store.ModelAlias{
		AliasID:       req.AliasID,
		DisplayName:   req.DisplayName,
		DesiredBuild:  req.DesiredBuild,
		PreviousBuild: req.PreviousBuild,
		Active:        active,
	}
	if err := s.store.UpsertModelAlias(alias); err != nil {
		s.logger.Error("upsert model alias failed", "alias_id", req.AliasID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save alias"))
		return
	}
	s.SyncModelCatalog()

	// Push the new desired build to every connected provider already serving the
	// alias so they converge without waiting to reconnect. Conservative policy
	// (DesiredModelsForProvider) means only providers that already advertise a
	// member of the alias are told.
	s.fanOutDesiredModels()

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
	if err := s.store.DeleteModelAlias(aliasID); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to delete alias"))
		return
	}
	s.SyncModelCatalog()
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted", "alias_id": aliasID})
}

// fanOutDesiredModels pushes the current desired_models to every connected
// provider that should learn it. It is gated per provider: only Swift-runtime
// providers at/above minProviderVersionForDesiredModels receive the message,
// because a pre-feature provider's strict decoder throws on unknown types.
// IDs+entries are collected under the registry's read lock and the sends happen
// afterward (SendDesiredModels takes the lock again).
func (s *Server) fanOutDesiredModels() {
	type target struct {
		id      string
		entries []protocol.DesiredModelEntry
	}
	var targets []target
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		id, backend, version := p.ID, p.Backend, p.Version
		p.Mu().Unlock()
		if !s.providerSupportsDesiredModels(backend, version) {
			return
		}
		if entries := s.registry.DesiredModelsForProvider(id); len(entries) > 0 {
			targets = append(targets, target{id: id, entries: entries})
		}
	})
	for _, t := range targets {
		if err := s.registry.SendDesiredModels(t.id, t.entries); err != nil {
			s.logger.Warn("failed to push desired_models", "provider_id", t.id, "error", err)
		}
	}
}

// providerSupportsDesiredModels reports whether a provider can receive the
// desired_models message: it must run the Swift backend and report a version at
// or above minProviderVersionForDesiredModels. A provider that reports no version
// is treated as too old (fail-closed).
func (s *Server) providerSupportsDesiredModels(backend, version string) bool {
	if !registry.BackendUsesSwiftRuntime(backend) {
		return false
	}
	if version == "" {
		return false
	}
	return !semverLess(version, minProviderVersionForDesiredModels)
}
