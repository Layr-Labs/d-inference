package api

// Retired HTTP handlers for provider log reports.
//
// A provider's unified log can contain inference-derived text. Both upload and
// retrieval are disabled so raw diagnostics cannot cross or remain exposed at
// the coordinator confidentiality boundary. Historical rows require a separate
// approved purge because deleting stored data is intentionally not implicit in
// this code change.

import "net/http"

// handleUploadLogReport permanently rejects legacy provider log uploads without
// reading or storing the request body. Keeping the route during rollout gives
// old providers an explicit terminal response while closing the data sink.
func (s *Server) handleUploadLogReport(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusGone, errorResponse(
		"log_report_upload_disabled",
		"provider log upload is disabled",
	))
}

// handleListLogReports permanently retires historical report discovery.
func (s *Server) handleListLogReports(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	writeJSON(w, http.StatusGone, errorResponse(
		"log_report_retrieval_disabled",
		"provider log retrieval is disabled",
	))
}

// handleGetLogReport permanently retires raw historical report retrieval.
func (s *Server) handleGetLogReport(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	writeJSON(w, http.StatusGone, errorResponse(
		"log_report_retrieval_disabled",
		"provider log retrieval is disabled",
	))
}
