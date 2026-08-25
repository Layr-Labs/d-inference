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

// handleUploadLogReport handles POST /v1/provider/log-report. The provider
// authenticates through requireAuth before this handler runs; callers receive
// an opaque support ID instead of supplying or receiving hardware identity.
func (s *Server) handleUploadLogReport(w http.ResponseWriter, r *http.Request) {
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
	reportID, err := s.store.StoreLogReport(accountID, body)
	if err != nil {
		s.logger.Error("log report: store failed", "account_id", accountID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to store log report"))
		return
	}

	s.logger.Info("log report uploaded", "report_id", reportID, "account_id", accountID, "size_bytes", len(body))
	writeJSON(w, http.StatusCreated, map[string]any{
		"status":     "stored",
		"report_id":  reportID,
		"size_bytes": len(body),
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
