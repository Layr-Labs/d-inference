package api

// HTTP handlers for explicit provider log-report upload and admin retrieval.
//
// A report is sent only when a provider operator invokes `darkbloom report`.
// Automatic provider reporting remains disabled. The Swift collector preserves
// macOS unified-log privacy redaction and limits collection to the Darkbloom
// provider subsystem.

import (
	"io"
	"net/http"
	"strconv"
)

const maxLogReportBodySize = 10 << 20 // 10 MB

// handleUploadLogReport handles POST /v1/provider/log-report?serial=XXX.
// The provider authenticates through requireAuth before this handler runs.
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
// It returns report metadata without log-data blobs.
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
	if value := r.URL.Query().Get("limit"); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil && parsed > 0 {
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
func (s *Server) handleGetLogReport(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
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
