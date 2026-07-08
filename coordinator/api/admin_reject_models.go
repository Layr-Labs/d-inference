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
//	                                        "models":[] = clear; a MISSING or null
//	                                        "models" key is a 400, not a clear)
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
// replacement of the reject set. An explicit empty list ({"models":[]}) clears
// the set; a MISSING or null "models" key is a 400 (see below). Every change is
// logged loudly (old set -> new set) — this is the same class of operator
// action as flipping EIGENINFERENCE_REJECT_MODELS, minus the restart.
func (s *Server) handleAdminPutRejectModels(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	// A pointer so a MISSING or null "models" key (nil) is distinguishable from
	// an explicit empty list (non-nil, len 0). Clearing the shed list is a
	// deliberate operation — {"models":[]} — because clearing it mid-incident
	// re-enables a model that was intentionally pulled from rotation. A body that
	// forgot the key ({}), typoed it ({"model":[...]} — decodeCappedJSON does not
	// disallow unknown fields), or sent JSON null ({"models":null}) all yield nil
	// here and MUST NOT silently clear the live set; they are rejected before
	// ReplaceRejectModels is called.
	var req struct {
		Models *[]string `json:"models"`
	}
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}
	if req.Models == nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			`missing required field "models" (send {"models":[]} to clear the shed list)`))
		return
	}
	models := *req.Models
	if len(models) > maxRejectModelsCount {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			fmt.Sprintf("too many models: %d (max %d)", len(models), maxRejectModelsCount)))
		return
	}
	// Validate everything before touching the live set: a bad entry must not
	// leave a half-applied replacement.
	set := make(map[string]bool, len(models))
	for i, model := range models {
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
	// A runtime shed must take effect on requests ALREADY in the queue, not just
	// future admission: fail the queued waiters for every model the new set sheds
	// so an operator pulling a model mid-incident isn't undercut by up to a full
	// queue window of requests still dispatching to it. Exclusive self-route
	// waiters are preserved (they bypass the shed at admission).
	failedQueued := s.failQueuedForShedModels()
	s.logger.Warn("model shed set REPLACED via /v1/admin/reject-models (runtime, no restart)",
		"old", previous,
		"new", current,
		"failed_queued", failedQueued,
		"remote_addr", r.RemoteAddr,
	)
	writeJSON(w, http.StatusOK, rejectModelsReplaceResponse{
		Models:   current,
		Previous: previous,
	})
}

// failQueuedForShedModels fails the queued waiters for every currently-queued
// model that the reject set now sheds, so a runtime shed-set change takes effect
// on in-flight queue entries instead of only future admission. It is scoped to
// models that actually have queue depth (catalog-bounded, cheap) and matches the
// resolved queue key against the reject set via modelShed. Exclusive self-route
// waiters are preserved inside the registry (they bypass the shed). Returns the
// number of queued requests failed.
func (s *Server) failQueuedForShedModels() int {
	q := s.registry.Queue()
	if q == nil {
		return 0
	}
	var shed []string
	for _, model := range q.QueuedModels() {
		if s.modelShed(model, model) {
			shed = append(shed, model)
		}
	}
	if len(shed) == 0 {
		return 0
	}
	return s.registry.RejectQueuedRequestsForShedModels(shed)
}
