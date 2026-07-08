package api

import (
	"fmt"
	"net/http"
	"strings"
	"unicode"
	"unicode/utf8"
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

// rejectModelsResponse is the wire shape of GET /v1/admin/reject-models.
type rejectModelsResponse struct {
	Models []string `json:"models"`
}

// rejectModelsReplaceResponse is the wire shape of PUT /v1/admin/reject-models:
// the installed set plus the set it replaced, both sorted.
type rejectModelsReplaceResponse struct {
	Models   []string `json:"models"`
	Previous []string `json:"previous"`
}

// Bounds on a PUT /v1/admin/reject-models payload. The reject set only ever
// holds model IDs from a catalog of a few dozen entries, and real IDs (e.g.
// "mlx-community/Qwen3.5-0.8B-MLX-4bit") are well under 100 bytes, so these
// are generous. They exist so a fat-fingered or hostile admin-key holder
// can't install megabyte-long or control-character-laden strings that would
// then be echoed into logs and JSON responses.
const (
	maxRejectModelsCount  = 128
	maxRejectModelNameLen = 256
)

// validateRejectModelName rejects entries that could garble logs or responses:
// over-long names, invalid UTF-8, and control characters. '/' stays legal —
// real model IDs contain it. The strings are only ever used as map keys,
// slog values, and JSON array elements (never filesystem paths or commands),
// so this is defense-in-depth for the admin surface, not an injection fix.
func validateRejectModelName(model string) error {
	if len(model) > maxRejectModelNameLen {
		return fmt.Errorf("model name exceeds %d bytes", maxRejectModelNameLen)
	}
	if !utf8.ValidString(model) {
		return fmt.Errorf("model name is not valid UTF-8")
	}
	for _, r := range model {
		if unicode.IsControl(r) {
			return fmt.Errorf("model name contains a control character")
		}
	}
	return nil
}

// handleAdminGetRejectModels serves GET /v1/admin/reject-models: the current
// reject set, sorted. Admin-gated and read-only.
func (s *Server) handleAdminGetRejectModels(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, rejectModelsResponse{Models: s.RejectModels()})
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
	if len(req.Models) > maxRejectModelsCount {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			fmt.Sprintf("too many models: %d (max %d)", len(req.Models), maxRejectModelsCount)))
		return
	}
	// Validate everything before touching the live set: a bad entry must not
	// leave a half-applied replacement.
	set := make(map[string]bool, len(req.Models))
	for i, model := range req.Models {
		model = strings.TrimSpace(model)
		if model == "" {
			continue // blank/whitespace-only entries are dropped, not errors
		}
		if err := validateRejectModelName(model); err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
				fmt.Sprintf("models[%d]: %v", i, err)))
			return
		}
		set[model] = true
	}
	previous, current := s.ReplaceRejectModels(set)
	s.logger.Warn("model shed set REPLACED via /v1/admin/reject-models (runtime, no restart)",
		"old", previous,
		"new", current,
		"remote_addr", r.RemoteAddr,
	)
	writeJSON(w, http.StatusOK, rejectModelsReplaceResponse{
		Models:   current,
		Previous: previous,
	})
}
