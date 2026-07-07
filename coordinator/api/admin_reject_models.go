package api

import (
	"net/http"
	"strings"
)

// Runtime shed-list ops.
//
// EIGENINFERENCE_REJECT_MODELS seeds the per-model reject set at startup
// (cmd/coordinator/main.go); before these endpoints existed, every shed flip
// (for example taking Gemma out of — or back into — rotation) required a
// coordinator restart, and each restart wipes the in-memory TTFT calibrator,
// TPS registries, breakers, and warm-pool state mid-recovery (1,589 provider
// sessions died to coordinator restarts in one 48h window). These endpoints
// mutate the set live:
//
//	GET /v1/admin/reject-models          -> {"models": ["..."]} (current set, sorted)
//	PUT /v1/admin/reject-models          <- {"models": ["..."]} (FULL replacement;
//	                                        empty list = shed nothing)
//
// Auth mirrors POST /v1/admin/drain (the other runtime-ops toggle): the routes
// are wrapped in requireAuth (which parses a Privy JWT into context and accepts
// the admin key as a pseudo-account — no credentials at all is a 401), and the
// handlers authorize via isAdminAuthorized (admin key OR Privy admin; anything
// else is a 403).

// handleAdminGetRejectModels serves GET /v1/admin/reject-models: the current
// reject set, sorted. Admin-gated and read-only.
func (s *Server) handleAdminGetRejectModels(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"models": s.RejectModels()})
}

// handleAdminPutRejectModels serves PUT /v1/admin/reject-models: full
// replacement of the reject set. An empty list sheds nothing. Every change is
// logged loudly (old set -> new set) — this is the same class of operator
// action as flipping EIGENINFERENCE_REJECT_MODELS, minus the restart.
func (s *Server) handleAdminPutRejectModels(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	var req struct {
		Models []string `json:"models"`
	}
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}
	set := make(map[string]bool, len(req.Models))
	for _, model := range req.Models {
		if model = strings.TrimSpace(model); model != "" {
			set[model] = true
		}
	}
	previous, current := s.ReplaceRejectModels(set)
	s.logger.Warn("model shed set REPLACED via /v1/admin/reject-models (runtime, no restart)",
		"old", previous,
		"new", current,
		"remote_addr", r.RemoteAddr,
	)
	writeJSON(w, http.StatusOK, map[string]any{
		"models":   current,
		"previous": previous,
	})
}
