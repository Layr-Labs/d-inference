package catalog

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
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

	// Takeover lets a public alias adopt the name of an EXISTING concrete model,
	// absorbing that same-named build as its previous_build (fallback). This is the
	// only way to migrate a live public name (e.g. "gemma-4-26b") onto a new
	// desired build without renaming what providers already advertise — used for
	// the 8-bit→4-bit gemma cutover. Fail-closed: only the exact shape
	// alias_id == previous_build == an existing concrete model id is permitted, and
	// desired_build must still be a distinct registered build. It does NOT touch
	// the absorbed model's catalog weight hash, so it never untrusts the providers
	// already serving it; they converge to the desired build via desired_models.
	Takeover bool `json:"takeover"`
}

// UpsertAlias creates or replaces a public model alias (idempotent on
// alias_id) and re-syncs the registry so the new desired-build pointer takes
// effect immediately, then declaratively pushes desired_models to every
// connected provider already serving the alias. POST /v1/admin/models/aliases.
func (s *Controller) UpsertAlias(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}

	var req aliasUpsertRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	req.AliasID = strings.TrimSpace(req.AliasID)
	req.DisplayName = strings.TrimSpace(req.DisplayName)
	req.DesiredBuild = strings.TrimSpace(req.DesiredBuild)
	req.PreviousBuild = strings.TrimSpace(req.PreviousBuild)

	if req.AliasID == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "alias_id is required", httpresponse.WithParam("alias_id")))
		return
	}
	// The alias is spliced into consumer-visible JSON (response bodies, SSE
	// chunk rewriting) and into the DELETE URL path — restrict it to the same
	// safe charset as registry ids (letters, digits, '.', '_', '-'; no slash so
	// it stays a single path segment) and a sane length.
	if len(req.AliasID) > maxAliasIDLength || !validRegistryIdentifier(req.AliasID, false) {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			"alias_id may only contain letters, digits, '.', '_' and '-' (max 128 chars)", httpresponse.WithParam("alias_id")))
		return
	}
	if req.DesiredBuild == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "desired_build is required", httpresponse.WithParam("desired_build")))
		return
	}
	s.modelAliasMutationMu.Lock()
	defer s.modelAliasMutationMu.Unlock()

	// Namespace + takeover rules. Normally an alias id must not collide with a
	// concrete model id (resolution would be ambiguous), and an alias may never
	// name itself as a member. `takeover` is the deliberate exception for the
	// public-name migration: an alias adopts the name of an existing concrete
	// model and absorbs that same-named build as its previous_build (fallback).
	collidingRec, _ := s.store().GetModelRegistryRecord(req.AliasID)
	idCollision := collidingRec != nil
	prior := s.priorAlias(req.AliasID)
	if prior != nil && prior.OpenRouterOnly {
		httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("invalid_request_error", "alias_id belongs to the dedicated OpenRouter alias endpoint", httpresponse.WithParam("alias_id")))
		return
	}

	// desired_build can NEVER equal the alias name (that would alias to itself).
	if req.DesiredBuild == req.AliasID {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			"desired_build cannot equal alias_id", httpresponse.WithParam("desired_build")))
		return
	}
	if idCollision {
		if !req.Takeover {
			httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("invalid_request_error",
				"alias_id collides with an existing model id (set takeover=true to adopt it as the alias's previous build)", httpresponse.WithParam("alias_id")))
			return
		}
		// Fail-closed: takeover only permits absorbing the SAME-named concrete
		// build as the alias fallback. previous_build must be exactly alias_id.
		if req.PreviousBuild != req.AliasID {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
				"takeover requires previous_build to equal alias_id (the concrete build absorbed as the alias fallback)", httpresponse.WithParam("previous_build")))
			return
		}
	} else if req.PreviousBuild == req.AliasID {
		// No concrete model of this name exists, so there is nothing to absorb.
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			"an alias cannot reference itself", httpresponse.WithParam("previous_build")))
		return
	}
	if req.PreviousBuild != "" && req.PreviousBuild == req.DesiredBuild {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "previous_build must differ from desired_build", httpresponse.WithParam("previous_build")))
		return
	}
	// Both builds must be registered models so we never alias to a phantom id.
	if rec, err := s.store().GetModelRegistryRecord(req.DesiredBuild); err != nil || rec == nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			"desired_build "+req.DesiredBuild+" is not a registered model", httpresponse.WithParam("desired_build")))
		return
	}
	if req.PreviousBuild != "" {
		if rec, err := s.store().GetModelRegistryRecord(req.PreviousBuild); err != nil || rec == nil {
			httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
				"previous_build "+req.PreviousBuild+" is not a registered model", httpresponse.WithParam("previous_build")))
			return
		}
	}

	active := true
	if req.Active != nil {
		active = *req.Active
	}
	retiredBuilds := retiredBuildsAfterUpsert(prior, req.DesiredBuild, req.PreviousBuild)
	if active {
		aliases, err := s.store().ListModelAliases()
		if err != nil {
			httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to validate alias members"))
			return
		}
		members := make(map[string]struct{}, 2+len(retiredBuilds))
		members[req.DesiredBuild] = struct{}{}
		if req.PreviousBuild != "" {
			members[req.PreviousBuild] = struct{}{}
		}
		for _, retired := range retiredBuilds {
			members[retired] = struct{}{}
		}
		if clone, conflict := concreteOpenRouterAliasUsingBuild(aliases, members); conflict {
			httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("invalid_request_error", "concrete model "+clone.SourceModel+" is pinned by OpenRouter alias "+clone.AliasID+"; delete or retarget that alias first"))
			return
		}
	}
	alias := &store.ModelAlias{
		AliasID:       req.AliasID,
		DisplayName:   req.DisplayName,
		DesiredBuild:  req.DesiredBuild,
		PreviousBuild: req.PreviousBuild,
		RetiredBuilds: retiredBuilds,

		Active: active,
	}

	if err := s.store().UpsertModelAlias(alias); err != nil {
		s.logger.Error("upsert model alias failed", "alias_id", req.AliasID, "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to save alias"))
		return
	}
	s.syncCatalog()

	saved, _, _ := s.store().GetModelAlias(req.AliasID)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"status": "ok", "alias": saved})
}

// maxAliasIDLength bounds the public alias id; it appears in URLs, response
// bodies, and SSE chunks, so it must stay short and single-segment.
const maxAliasIDLength = 128

// ListAliases returns standard rollout aliases. OpenRouter-only feed
// aliases have a dedicated management endpoint.
func (s *Controller) ListAliases(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliases, err := s.store().ListModelAliases()
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to list aliases"))
		return
	}
	standard := aliases[:0]
	for _, alias := range aliases {
		if !alias.OpenRouterOnly {
			standard = append(standard, alias)
		}
	}
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"aliases": standard})

}

// DeleteAlias removes an alias. DELETE /v1/admin/models/aliases/{aliasID}.
func (s *Controller) DeleteAlias(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliasID := strings.TrimSpace(r.PathValue("aliasID"))
	if aliasID == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "alias id is required"))
		return
	}
	if alias, found, err := s.store().GetModelAlias(aliasID); err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to get alias"))
		return
	} else if found && alias.OpenRouterOnly {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("invalid_request_error", "OpenRouter-only alias must be deleted through its dedicated endpoint"))
		return
	}
	if err := s.store().DeleteModelAlias(aliasID); err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to delete alias"))
		return
	}
	s.syncCatalog()
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{"status": "deleted", "alias_id": aliasID})
}
