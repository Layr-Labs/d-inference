package api

// HTTP handlers for provider log report upload and admin retrieval.
//
// Providers upload their 24h unified logs via POST /v1/provider/log-report.
// Admins list and retrieve reports via GET /v1/admin/log-reports.

import (
	"io"
	"net/http"
	"strconv"
)

const maxLogReportBodySize = 10 << 20 // 10 MB

// handleUploadLogReport handles POST /v1/provider/log-report?serial=XXX.
// The provider identifies itself via API key auth (requireAuth). The serial
// number is sent as a query param since the provider knows its own serial.
func (s *Server) handleUploadLogReport(w http.ResponseWriter, r *http.Request) {
	serial := r.URL.Query().Get("serial")
	if serial == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "serial query parameter is required"))
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxLogReportBodySize+1))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read request body"))
		return
	}
	if len(body) == 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "empty log data"))
		return
	}
	if len(body) > maxLogReportBodySize {
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("invalid_request_error", "log data exceeds 10MB limit"))
		return
	}

	accountID := s.resolveAccountID(r)

	if err := s.store.StoreLogReport(serial, "", accountID, body); err != nil {
		s.logger.Error("log report: store failed", "serial", serial, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to store log report"))
		return
	}

	s.logger.Info("log report uploaded", "serial", serial, "size_bytes", len(body))
	writeJSON(w, http.StatusCreated, map[string]any{
		"status":     "stored",
		"serial":     serial,
		"size_bytes": len(body),
	})
}

// handleListLogReports handles GET /v1/admin/log-reports?serial=XXX&limit=10.
// Admin-only. Returns log report metadata without the log data blobs.
func (s *Server) handleListLogReports(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	serial := r.URL.Query().Get("serial")
	if serial == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "serial query parameter is required"))
		return
	}

	limit := 10
	if v := r.URL.Query().Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}

	reports, err := s.store.GetLogReports(serial, limit)
	if err != nil {
		s.logger.Error("log report: list failed", "serial", serial, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list log reports"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"serial":  serial,
		"reports": reports,
		"count":   len(reports),
	})
}

// handleGetLogReport handles GET /v1/admin/log-reports/{id}.
// Admin-only. Returns the full log data as text/plain.
func (s *Server) handleGetLogReport(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	idStr := r.PathValue("id")
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil || id <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid report id"))
		return
	}

	report, err := s.store.GetLogReport(id)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "log report not found"))
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Length", strconv.FormatInt(report.LogSizeBytes, 10))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(report.LogData)
}
