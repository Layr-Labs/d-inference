package api

import (
	"context"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleAdminRequestOutcomes exposes bounded source observations, not a traffic
// fulfillment percentage. Process counters describe this process lifetime only.
func (s *Server) handleAdminRequestOutcomes(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	until := time.Now()
	if value := r.URL.Query().Get("until"); value != "" {
		var err error
		until, err = time.Parse(time.RFC3339Nano, value)
		if err != nil {
			writeJSON(w, 400, errorResponse("invalid_request_error", "until must be RFC3339"))
			return
		}
	}
	since := parseSince(r)
	if !since.Before(until) {
		writeJSON(w, 400, errorResponse("invalid_request_error", "since must precede until"))
		return
	}
	limit := parseLimit(r, defaultBrowseLimit)
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rows, err := s.store.RequestOutcomes(ctx, since, until, limit)
	if err != nil {
		writeJSON(w, 503, errorResponse("service_unavailable", "request outcome data unavailable"))
		return
	}
	health := map[string]any{"available": false}
	if q := s.requestOutcomes; q != nil {
		health = map[string]any{"available": true, "received": q.received.Load(), "snapshots_written": q.written.Load(), "snapshots_dropped": q.dropped.Load(), "snapshots_write_failed": q.failed.Load(), "snapshots_queued": len(q.ch)}
	}
	writeJSON(w, 200, map[string]any{"schema_version": store.RequestOutcomeSchemaVersion, "data": rows, "count": len(rows), "since": since, "until": until, "possibly_truncated": len(rows) == limit, "coverage": "observed_received_cohort", "persistence": "unsampled_best_effort", "process_counters": health})
}
