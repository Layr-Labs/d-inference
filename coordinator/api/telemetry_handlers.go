package api

import (
	"net/http"
)

// handleTelemetryIngest permanently rejects client-supplied telemetry without
// reading, decoding, storing, logging, or forwarding the request body. Keeping
// the route gives old providers an explicit terminal response during rollout.
func (s *Server) handleTelemetryIngest(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusGone, errorResponse(
		"telemetry_ingest_disabled",
		"client telemetry ingestion is disabled",
	))
}
