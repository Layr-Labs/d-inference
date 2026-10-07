package operations

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// HandleAdminMetrics serves JSON or Prometheus metrics after admin authorization.
func (s *Handler) HandleAdminMetrics(w http.ResponseWriter, r *http.Request) {
	if !s.access.IsAdminAuthorized(w, r) {
		return
	}
	snap := s.metrics().Snapshot()
	if r.URL.Query().Get("format") == "prom" {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(snap.RenderProm()))
		return
	}
	httpx.WriteJSON(w, http.StatusOK, snap)
}
