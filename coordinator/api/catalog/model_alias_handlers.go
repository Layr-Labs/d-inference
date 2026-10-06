package catalog

import (
	"encoding/json"
	"net/http"
	"strings"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	aliaspolicy "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/aliaspolicy"
	registration "github.com/eigeninference/d-inference/coordinator/internal/api/catalog/registration"
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

// HandleModelAliasUpsert creates or replaces a public model alias (idempotent on
// alias_id) and re-syncs the registry so the new desired-build pointer takes
// effect immediately, then declaratively pushes desired_models to every
// connected provider already serving the alias. POST /v1/admin/models/aliases.
func (s *Owner) HandleModelAliasUpsert(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.access.RequirePublishingAPIKey(w, r); !ok {
		return
	}

	var req aliasUpsertRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}

	req.AliasID = strings.TrimSpace(req.AliasID)
	req.DisplayName = strings.TrimSpace(req.DisplayName)
	req.DesiredBuild = strings.TrimSpace(req.DesiredBuild)
	req.PreviousBuild = strings.TrimSpace(req.PreviousBuild)

	if req.AliasID == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "alias_id is required", httpx.WithParam("alias_id")))
		return
	}
	// The alias is spliced into consumer-visible JSON (response bodies, SSE
	// chunk rewriting) and into the DELETE URL path — restrict it to the same
	// safe charset as registry ids (letters, digits, '.', '_', '-'; no slash so
	// it stays a single path segment) and a sane length.
	if len(req.AliasID) > maxAliasIDLength || !registration.ValidRegistryIdentifier(req.AliasID, false) {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"alias_id may only contain letters, digits, '.', '_' and '-' (max 128 chars)", httpx.WithParam("alias_id")))
		return
	}
	if req.DesiredBuild == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "desired_build is required", httpx.WithParam("desired_build")))
		return
	}
	s.modelAliasMutationMu.Lock()
	defer s.modelAliasMutationMu.Unlock()

	// Namespace + takeover rules. Normally an alias id must not collide with a
	// concrete model id (resolution would be ambiguous), and an alias may never
	// name itself as a member. `takeover` is the deliberate exception for the
	// public-name migration: an alias adopts the name of an existing concrete
	// model and absorbs that same-named build as its previous_build (fallback).
	collidingRec, _ := s.store.GetModelRegistryRecord(req.AliasID)
	idCollision := collidingRec != nil
	prior := s.priorAlias(req.AliasID)
	if prior != nil && prior.OpenRouterOnly {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", "alias_id belongs to the dedicated OpenRouter alias endpoint", httpx.WithParam("alias_id")))
		return
	}

	// desired_build can NEVER equal the alias name (that would alias to itself).
	if req.DesiredBuild == req.AliasID {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"desired_build cannot equal alias_id", httpx.WithParam("desired_build")))
		return
	}
	if idCollision {
		if !req.Takeover {
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error",
				"alias_id collides with an existing model id (set takeover=true to adopt it as the alias's previous build)", httpx.WithParam("alias_id")))
			return
		}
		// Fail-closed: takeover only permits absorbing the SAME-named concrete
		// build as the alias fallback. previous_build must be exactly alias_id.
		if req.PreviousBuild != req.AliasID {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
				"takeover requires previous_build to equal alias_id (the concrete build absorbed as the alias fallback)", httpx.WithParam("previous_build")))
			return
		}
	} else if req.PreviousBuild == req.AliasID {
		httpx.
			// No concrete model of this name exists, so there is nothing to absorb.
			WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
				"an alias cannot reference itself", httpx.WithParam("previous_build")))
		return
	}
	if req.PreviousBuild != "" && req.PreviousBuild == req.DesiredBuild {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "previous_build must differ from desired_build", httpx.WithParam("previous_build")))
		return
	}
	// Both builds must be registered models so we never alias to a phantom id.
	if rec, err := s.store.GetModelRegistryRecord(req.DesiredBuild); err != nil || rec == nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"desired_build "+req.DesiredBuild+" is not a registered model", httpx.WithParam("desired_build")))
		return
	}
	if req.PreviousBuild != "" {
		if rec, err := s.store.GetModelRegistryRecord(req.PreviousBuild); err != nil || rec == nil {
			httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
				"previous_build "+req.PreviousBuild+" is not a registered model", httpx.WithParam("previous_build")))
			return
		}
	}

	active := true
	if req.Active != nil {
		active = *req.Active
	}
	retiredBuilds := aliaspolicy.RetiredBuildsAfterUpsert(prior, req.DesiredBuild, req.PreviousBuild)
	if active {
		aliases, err := s.store.ListModelAliases()
		if err != nil {
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to validate alias members"))
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
		if clone, conflict := aliaspolicy.ConcreteOpenRouterAliasUsingBuild(aliases, members); conflict {
			httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("invalid_request_error", "concrete model "+clone.SourceModel+" is pinned by OpenRouter alias "+clone.AliasID+"; delete or retarget that alias first"))
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

	if err := s.store.UpsertModelAlias(alias); err != nil {
		s.logger.Error("upsert model alias failed", "alias_id", req.AliasID, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to save alias"))
		return
	}
	s.SyncModelCatalog()

	saved, _, _ := s.store.GetModelAlias(req.AliasID)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": "ok", "alias": saved})
}

// maxAliasIDLength bounds the public alias id; it appears in URLs, response
// bodies, and SSE chunks, so it must stay short and single-segment.
const maxAliasIDLength = 128

// priorAlias fetches the existing alias definition, or nil when none exists
// (or the store errored — treated as "no prior" since upsert will surface real
// store failures itself).
func (s *Owner) priorAlias(aliasID string) *store.ModelAlias {
	prior, found, err := s.store.GetModelAlias(aliasID)
	if err != nil || !found {
		return nil
	}
	return prior
}

// HandleModelAliasList returns standard rollout aliases. OpenRouter-only feed
// aliases have a dedicated management endpoint.
func (s *Owner) HandleModelAliasList(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.access.RequirePublishingAPIKey(w, r); !ok {
		return
	}
	aliases, err := s.store.ListModelAliases()
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to list aliases"))
		return
	}
	standard := aliases[:0]
	for _, alias := range aliases {
		if !alias.OpenRouterOnly {
			standard = append(standard, alias)
		}
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"aliases": standard})

}

// HandleModelAliasDelete removes an alias. DELETE /v1/admin/models/aliases/{aliasID}.
func (s *Owner) HandleModelAliasDelete(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.access.RequirePublishingAPIKey(w, r); !ok {
		return
	}
	aliasID := strings.TrimSpace(r.PathValue("aliasID"))
	if aliasID == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "alias id is required"))
		return
	}
	if alias, found, err := s.store.GetModelAlias(aliasID); err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to get alias"))
		return
	} else if found && alias.OpenRouterOnly {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("invalid_request_error", "OpenRouter-only alias must be deleted through its dedicated endpoint"))
		return
	}
	if err := s.store.DeleteModelAlias(aliasID); err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to delete alias"))
		return
	}
	s.SyncModelCatalog()
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": "deleted", "alias_id": aliasID})
}

// FanOutDesiredModels pushes the current desired_models to every connected
// provider that should learn it. Only Swift-runtime providers receive the
// message (ProviderSupportsDesiredModels).
// IDs+entries are collected under the registry's read lock and the sends happen
// afterward (SendDesiredModels takes the lock again).
// Return false if any send fails so callers can retry the committed mutation.
// Failed snapshots are not deduplicated by SendDesiredModels on that retry.
func (s *Owner) FanOutDesiredModels() bool {
	// Collect eligible provider IDs under the registry read lock, then compute
	// entries and send AFTER releasing it. DesiredModelsForProvider and
	// SendDesiredModels each take r.mu themselves, so calling them inside the
	// ForEachProvider callback (which already holds r.mu.RLock) would nest the
	// read lock — a deadlock once a writer queues between the outer and inner
	// RLock (Go's RWMutex blocks new readers while a writer waits).
	var eligibleIDs []string
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		id, backend := p.ID, p.Backend
		p.Mu().Unlock()
		if s.ProviderSupportsDesiredModels(backend) {
			eligibleIDs = append(eligibleIDs, id)
		}
	})
	delivered := true
	for _, id := range eligibleIDs {
		// Empty entry sets are sent too: "nothing is desired" is meaningful
		// state — it marks a provider's in-flight prefetch for a now-deleted/
		// repointed alias as stale (see SendDesiredModels).
		if err := s.registry.SendDesiredModels(id, s.registry.DesiredModelsForProvider(id)); err != nil {
			s.logger.Warn("failed to push desired_models", "provider_id", id, "error", err)
			delivered = false
		}
	}
	return delivered
}

// ProviderSupportsDesiredModels reports whether a provider can receive the
// desired_models message: only the Swift runtime understands it. Every Swift
// build above the routing floor does; the pre-0.5.17 builds whose strict
// decoder disconnected on it are long retired.
func (s *Owner) ProviderSupportsDesiredModels(backend string) bool {
	return registry.BackendUsesSwiftRuntime(backend)
}
