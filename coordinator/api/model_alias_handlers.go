package api

import (
	"encoding/json"
	"net/http"
	"strings"

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
	// The alias is spliced into consumer-visible JSON (response bodies, SSE
	// chunk rewriting) and into the DELETE URL path — restrict it to the same
	// safe charset as registry ids (letters, digits, '.', '_', '-'; no slash so
	// it stays a single path segment) and a sane length.
	if len(req.AliasID) > maxAliasIDLength || !validRegistryIdentifier(req.AliasID, false) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"alias_id may only contain letters, digits, '.', '_' and '-' (max 128 chars)", withParam("alias_id")))
		return
	}
	if req.DesiredBuild == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "desired_build is required", withParam("desired_build")))
		return
	}
	// Namespace + takeover rules. Normally an alias id must not collide with a
	// concrete model id (resolution would be ambiguous), and an alias may never
	// name itself as a member. `takeover` is the deliberate exception for the
	// public-name migration: an alias adopts the name of an existing concrete
	// model and absorbs that same-named build as its previous_build (fallback).
	collidingRec, _ := s.store.GetModelRegistryRecord(req.AliasID)
	idCollision := collidingRec != nil

	// desired_build can NEVER equal the alias name (that would alias to itself).
	if req.DesiredBuild == req.AliasID {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"desired_build cannot equal alias_id", withParam("desired_build")))
		return
	}
	if idCollision {
		if !req.Takeover {
			writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error",
				"alias_id collides with an existing model id (set takeover=true to adopt it as the alias's previous build)", withParam("alias_id")))
			return
		}
		// Fail-closed: takeover only permits absorbing the SAME-named concrete
		// build as the alias fallback. previous_build must be exactly alias_id.
		if req.PreviousBuild != req.AliasID {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				"takeover requires previous_build to equal alias_id (the concrete build absorbed as the alias fallback)", withParam("previous_build")))
			return
		}
	} else if req.PreviousBuild == req.AliasID {
		// No concrete model of this name exists, so there is nothing to absorb.
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"an alias cannot reference itself", withParam("previous_build")))
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
		RetiredBuilds: retiredBuildsAfterUpsert(s.priorAlias(req.AliasID), req.DesiredBuild, req.PreviousBuild),
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

// maxAliasIDLength bounds the public alias id; it appears in URLs, response
// bodies, and SSE chunks, so it must stay short and single-segment.
const maxAliasIDLength = 128

// maxRetiredBuilds bounds the per-alias lineage list; the oldest retirements
// are dropped first once a (pathologically) churned alias exceeds it.
const maxRetiredBuilds = 16

// priorAlias fetches the existing alias definition, or nil when none exists
// (or the store errored — treated as "no prior" since upsert will surface real
// store failures itself).
func (s *Server) priorAlias(aliasID string) *store.ModelAlias {
	prior, found, err := s.store.GetModelAlias(aliasID)
	if err != nil || !found {
		return nil
	}
	return prior
}

// retiredBuildsAfterUpsert computes the alias's lineage after an upsert: prior
// retired builds, plus any prior desired/previous member rotated out by the new
// pointers, minus any build the new pointers re-promote to membership. Bounded
// to maxRetiredBuilds (oldest dropped first). The lineage lets the registration
// gate recognize a provider that was offline through a retirement as part of
// the alias's fleet.
func retiredBuildsAfterUpsert(prior *store.ModelAlias, newDesired, newPrevious string) []string {
	if prior == nil {
		return nil
	}
	isMember := func(b string) bool { return b == newDesired || b == newPrevious }
	var retired []string
	seen := make(map[string]struct{})
	add := func(b string) {
		if b == "" || isMember(b) {
			return
		}
		if _, dup := seen[b]; dup {
			return
		}
		seen[b] = struct{}{}
		retired = append(retired, b)
	}
	for _, b := range prior.RetiredBuilds {
		add(b)
	}
	add(prior.DesiredBuild)
	add(prior.PreviousBuild)
	if len(retired) > maxRetiredBuilds {
		retired = retired[len(retired)-maxRetiredBuilds:]
	}
	return retired
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
	// Push the post-delete desired state to the fleet. A provider whose ONLY
	// desired entry came from this alias receives an EMPTY set — that is what
	// marks its in-flight prefetch stale; without it the prefetch would
	// complete, hard-swap, and drop a build the operator may still want served.
	s.fanOutDesiredModels()
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted", "alias_id": aliasID})
}

// fanOutDesiredModels pushes the current desired_models to every connected
// provider that should learn it. It is gated per provider: only Swift-runtime
// providers at/above minProviderVersionForDesiredModels receive the message,
// because a pre-feature provider's strict decoder throws on unknown types.
// IDs+entries are collected under the registry's read lock and the sends happen
// afterward (SendDesiredModels takes the lock again).
func (s *Server) fanOutDesiredModels() {
	// Collect eligible provider IDs under the registry read lock, then compute
	// entries and send AFTER releasing it. DesiredModelsForProvider and
	// SendDesiredModels each take r.mu themselves, so calling them inside the
	// ForEachProvider callback (which already holds r.mu.RLock) would nest the
	// read lock — a deadlock once a writer queues between the outer and inner
	// RLock (Go's RWMutex blocks new readers while a writer waits).
	var eligibleIDs []string
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		id, backend, version := p.ID, p.Backend, p.Version
		p.Mu().Unlock()
		if s.providerSupportsDesiredModels(backend, version) {
			eligibleIDs = append(eligibleIDs, id)
		}
	})
	for _, id := range eligibleIDs {
		// Empty entry sets are sent too: "nothing is desired" is meaningful
		// state — it marks a provider's in-flight prefetch for a now-deleted/
		// repointed alias as stale (see SendDesiredModels).
		if err := s.registry.SendDesiredModels(id, s.registry.DesiredModelsForProvider(id)); err != nil {
			s.logger.Warn("failed to push desired_models", "provider_id", id, "error", err)
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
