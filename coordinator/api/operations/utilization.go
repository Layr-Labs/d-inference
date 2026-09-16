package operations

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// Utilization serves GET /v1/admin/utilization: the full
// network-utilization snapshot (demand/capacity across the warm-serving and
// token-budget axes, plus a per-model breakdown and the bottleneck model).
// Admin-gated and read-only.
func (s *Controller) Utilization(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeTelemetry(w, r) {
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, s.utilization())
}
