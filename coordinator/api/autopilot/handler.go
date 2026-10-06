package autopilot

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"time"

	policy "github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Controller is the operator-facing control surface, independent of HTTP auth.
type Controller interface {
	SetAutopilotPaused(bool) bool
	AutopilotSnapshot() policy.Summary
}

// Handler serves an already-authorized admin request. The parent API package
// owns authentication and admin authorization at its route adapter.
type Handler struct {
	Controller Controller
	Ledger     store.AutopilotStore
}

func (h Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		var body struct {
			Paused *bool `json:"paused"`
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1024)
		decoder := json.NewDecoder(r.Body)
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&body); err != nil || body.Paused == nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "paused is required"))
			return
		}
		var trailing any
		if err := decoder.Decode(&trailing); err != io.EOF {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "exactly one JSON object is required"))
			return
		}
		if !h.Controller.SetAutopilotPaused(*body.Paused) {
			writeJSON(w, http.StatusConflict, errorResponse("invalid_request_error", "Autopilot is not configured"))
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"summary": h.Controller.AutopilotSnapshot()})
		return
	}
	records := []store.AutopilotRecord{}
	if h.Ledger != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		var err error
		records, err = h.Ledger.AutopilotRecords(ctx, time.Now().Add(-24*time.Hour), 200)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, errorResponse("server_error", "Autopilot ledger unavailable"))
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"summary": h.Controller.AutopilotSnapshot(), "events": records})
}
