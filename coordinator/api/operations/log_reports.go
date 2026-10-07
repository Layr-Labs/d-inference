package operations

// HTTP handlers for explicit provider log-report upload and admin retrieval.
//
// A report is sent only when a provider operator invokes `darkbloom report`.
// Automatic provider reporting remains disabled. The Swift collector preserves
// macOS unified-log privacy redaction and limits collection to the Darkbloom
// provider subsystem.

import (
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const maxLogReportBodySize = 10 << 20 // 10 MB

// handleUploadLogReport handles POST /v1/provider/log-report. The provider
// authenticates through requireAuth before this handler runs; callers receive
// an opaque support ID instead of supplying or receiving hardware identity.
func (s *Handler) HandleUploadLogReport(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Has("serial") {
		httpx.WriteJSON(w, http.StatusUpgradeRequired, httpx.ErrorResponse("upgrade_required", "update darkbloom before uploading support reports"))
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxLogReportBodySize+1))
	if err != nil {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "failed to read request body"))
		return
	}
	if len(body) == 0 {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "empty log data"))
		return
	}
	if len(body) > maxLogReportBodySize {
		httpx.WriteJSON(w, http.StatusRequestEntityTooLarge, httpx.ErrorResponse("invalid_request_error", "log data exceeds 10MB limit"))
		return
	}

	accountID := access.ResolveAccountID(r)
	reportID, err := s.store.StoreLogReport(accountID, body)
	if errors.Is(err, store.ErrErasureConflict) {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("account_deleted", "Log uploads are unavailable for an erased account"))
		return
	}
	if err != nil {
		s.logger.Error("log report: store failed", "account_id", accountID, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to store log report"))
		return
	}

	s.logger.Info("log report uploaded", "report_id", reportID, "account_id", accountID, "size_bytes", len(body))
	httpx.WriteJSON(w, http.StatusCreated, map[string]any{
		"status":     "stored",
		"report_id":  reportID,
		"size_bytes": len(body),
	})
}

// handleGetLogReport handles GET /v1/admin/log-reports/{id}.
func (s *Handler) HandleGetLogReport(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}

	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil || id <= 0 {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "invalid report id"))
		return
	}

	report, err := s.store.GetLogReport(id)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("not_found", "log report not found"))
		return
	}

	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Length", strconv.FormatInt(report.LogSizeBytes, 10))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(report.LogData)
}
