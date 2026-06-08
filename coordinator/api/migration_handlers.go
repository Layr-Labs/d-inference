package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// StartMigrationController launches the background ramp/drain control loop. Call
// once at startup; it runs until ctx is cancelled.
func (s *Server) StartMigrationController(ctx context.Context) {
	newMigrationController(s).Start(ctx)
}

type migrationStartRequest struct {
	AliasID        string `json:"alias_id"`
	FromBuild      string `json:"from_build"`
	ToBuild        string `json:"to_build"`
	BatchSize      int    `json:"batch_size"`
	MaxStepPercent int    `json:"max_step_percent"`
}

// handleMigrationStart begins a zero-downtime cutover for an alias from one
// build to another. POST /v1/admin/migrations.
func (s *Server) handleMigrationStart(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}

	var req migrationStartRequest
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	req.AliasID = strings.TrimSpace(req.AliasID)
	req.FromBuild = strings.TrimSpace(req.FromBuild)
	req.ToBuild = strings.TrimSpace(req.ToBuild)
	if req.AliasID == "" || req.FromBuild == "" || req.ToBuild == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "alias_id, from_build and to_build are required"))
		return
	}
	if req.FromBuild == req.ToBuild {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "from_build and to_build must differ"))
		return
	}

	alias, ok, err := s.store.GetModelAlias(req.AliasID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to read alias"))
		return
	}
	if !ok {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "alias "+req.AliasID+" does not exist — create it first"))
		return
	}
	// Both builds must be registered models.
	if rec, err := s.store.GetModelRegistryRecord(req.ToBuild); err != nil || rec == nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "to_build is not a registered model", withParam("to_build")))
		return
	}
	if rec, err := s.store.GetModelRegistryRecord(req.FromBuild); err != nil || rec == nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "from_build is not a registered model", withParam("from_build")))
		return
	}

	// Reject if a migration for this alias is already in progress (active OR
	// paused). Overlapping migrations would strand the previous split's builds at
	// nonzero weight (the controller only adjusts this migration's from/to), so
	// the old build keeps taking alias traffic. Pausing does NOT make a restart
	// safe — the paused split's `to` build is still at nonzero weight — so a
	// paused migration blocks too; roll it back first, then start the next leg.
	if existing, ok, err := s.store.GetModelMigration(req.AliasID); err == nil && ok &&
		(existing.Status == store.MigrationActive || existing.Status == store.MigrationPaused) {
		writeJSON(w, http.StatusConflict, errorResponse("conflict",
			"a migration for "+req.AliasID+" is already in progress (status "+existing.Status+", from "+existing.FromBuild+" to "+existing.ToBuild+"); roll it back before starting another"))
		return
	}

	// Ensure the alias contains both builds. from keeps its current weight (or
	// 100 if absent); to starts drained at 0 and the controller ramps it up.
	if buildWeight(alias, req.FromBuild) < 0 {
		setBuildWeight(alias, req.FromBuild, 100)
	}
	if buildWeight(alias, req.ToBuild) < 0 {
		setBuildWeight(alias, req.ToBuild, 0)
	}
	if err := s.store.UpsertModelAlias(alias); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to update alias"))
		return
	}

	batch := req.BatchSize
	if batch <= 0 {
		batch = 1
	}
	step := req.MaxStepPercent
	if step <= 0 {
		step = 25
	}
	m := &store.ModelMigration{
		AliasID:        req.AliasID,
		FromBuild:      req.FromBuild,
		ToBuild:        req.ToBuild,
		BatchSize:      batch,
		MaxStepPercent: step,
		Status:         store.MigrationActive,
	}
	if err := s.store.UpsertModelMigration(m); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to start migration"))
		return
	}
	s.SyncModelCatalog()
	s.ddIncr("migration.started", []string{"alias:" + req.AliasID})
	s.logger.Info("migration started", "alias", req.AliasID, "from", req.FromBuild, "to", req.ToBuild, "batch", batch, "step", step)

	// Diagnostic: warn (don't refuse — capable providers may be added later) if
	// no current old-build provider's hardware can fit the new build, since the
	// ramp can't progress until one exists.
	resp := map[string]any{"status": "ok", "migration": m}
	canFit := false
	for _, id := range s.registry.ProvidersServingBuild(req.FromBuild) {
		if s.registry.ProviderCanFitBuild(id, req.ToBuild) {
			canFit = true
			break
		}
	}
	if !canFit {
		warning := "no current provider serving " + req.FromBuild + " has the hardware to fit " + req.ToBuild +
			"; the ramp will not progress until a capable provider is available"
		s.logger.Warn("migration start: "+warning, "alias", req.AliasID)
		resp["warning"] = warning
	}
	writeJSON(w, http.StatusOK, resp)
}

// handleMigrationList returns all migrations with live progress. GET /v1/admin/migrations.
func (s *Server) handleMigrationList(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	migs, err := s.store.ListModelMigrations()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list migrations"))
		return
	}
	out := make([]map[string]any, 0, len(migs))
	for _, m := range migs {
		toWeight := 0
		if alias, ok, _ := s.store.GetModelAlias(m.AliasID); ok {
			toWeight = buildWeight(alias, m.ToBuild)
			if toWeight < 0 {
				toWeight = 0
			}
		}
		out = append(out, map[string]any{
			"migration":      m,
			"to_weight":      toWeight,
			"providers_from": len(s.registry.ProvidersServingBuild(m.FromBuild)),
			"providers_to":   len(s.registry.ProvidersServingBuild(m.ToBuild)),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"migrations": out})
}

// handleMigrationAction applies pause / resume / rollback to a migration.
// POST /v1/admin/migrations/{aliasID}/{action}.
func (s *Server) handleMigrationAction(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requirePublishingAPIKey(w, r); !ok {
		return
	}
	aliasID := strings.TrimSpace(r.PathValue("aliasID"))
	action := strings.TrimSpace(r.PathValue("action"))

	// Serialize with the controller tick so a rollback/pause can't be clobbered
	// by an in-flight ramp (and vice versa). The whole read-modify-write runs
	// under the lock.
	s.migrationMu.Lock()
	defer s.migrationMu.Unlock()

	m, ok, err := s.store.GetModelMigration(aliasID)
	if err != nil || !ok {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no migration for alias "+aliasID))
		return
	}

	switch action {
	case "pause":
		m.Status = store.MigrationPaused
	case "resume":
		m.Status = store.MigrationActive
	case "rollback":
		m.Status = store.MigrationRolledBack
	default:
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "unknown action: "+action))
		return
	}

	// Persist the status change FIRST so that even if the weight revert below
	// fails, the controller (which re-reads status under the same lock) will not
	// keep ramping a rolled-back migration.
	if err := s.store.UpsertModelMigration(m); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to update migration"))
		return
	}

	if action == "rollback" {
		// Revert all traffic to the old build immediately.
		alias, aok, aerr := s.store.GetModelAlias(aliasID)
		if aerr != nil {
			writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to read alias for rollback"))
			return
		}
		if aok {
			setBuildWeight(alias, m.FromBuild, 100)
			setBuildWeight(alias, m.ToBuild, 0)
			if err := s.store.UpsertModelAlias(alias); err != nil {
				writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to revert alias weights"))
				return
			}
		} else {
			// Alias vanished out from under the migration — nothing to revert,
			// but the rollback status is already recorded. Log it loudly.
			s.logger.Warn("migration rollback: alias not found, only status updated", "alias", aliasID)
		}
	}
	s.SyncModelCatalog()
	s.ddIncr("migration.action", []string{"alias:" + aliasID, "action:" + action})
	s.logger.Info("migration action", "alias", aliasID, "action", action, "status", m.Status)
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "migration": m})
}

// buildWeight returns the weight of a build in the alias, or -1 if absent.
func buildWeight(alias *store.ModelAlias, buildID string) int {
	if alias == nil {
		return -1
	}
	for _, b := range alias.Builds {
		if b.BuildID == buildID {
			return b.Weight
		}
	}
	return -1
}
