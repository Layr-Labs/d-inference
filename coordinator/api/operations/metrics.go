package operations

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// Metrics returns the metrics snapshot in JSON or Prometheus text.
func (s *Controller) Metrics(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeMetrics(w, r) {
		return
	}
	snap := s.metrics()
	if r.URL.Query().Get("format") == "prom" {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(snap.RenderProm()))
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, snap)
}
