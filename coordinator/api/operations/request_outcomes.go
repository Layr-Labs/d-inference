package operations

import (
	"context"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// RequestOutcomes exposes bounded source observations, not a traffic
// fulfillment percentage. Process counters describe this process lifetime only.
func (s *Controller) RequestOutcomes(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	until := time.Now()
	if value := r.URL.Query().Get("until"); value != "" {
		var err error
		until, err = time.Parse(time.RFC3339Nano, value)
		if err != nil {
			httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", "until must be RFC3339"))
			return
		}
	}
	since := parseSince(r)
	if !since.Before(until) {
		httpresponse.WriteJSON(w, 400, httpresponse.ErrorBody("invalid_request_error", "since must precede until"))
		return
	}
	limit := parseLimit(r, defaultBrowseLimit)
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rows, err := s.store().RequestOutcomes(ctx, since, until, limit)
	if err != nil {
		httpresponse.WriteJSON(w, 503, httpresponse.ErrorBody("service_unavailable", "request outcome data unavailable"))
		return
	}
	health := map[string]any{"available": false}
	if q := s.outcomes(); q != nil {
		stats := q.Stats()
		health = map[string]any{"available": true, "received": stats.Received, "snapshots_written": stats.Written, "snapshots_dropped": stats.Dropped, "snapshots_write_failed": stats.Failed, "snapshots_queued": stats.Queued}
	}
	httpresponse.WriteJSON(w, 200, map[string]any{"schema_version": store.RequestOutcomeSchemaVersion, "data": rows, "count": len(rows), "since": since, "until": until, "possibly_truncated": len(rows) == limit, "coverage": "observed_received_cohort", "persistence": "unsampled_best_effort", "process_counters": health})
}
