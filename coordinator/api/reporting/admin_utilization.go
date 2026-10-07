package reporting

import (
	"net/http"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// handleAdminUtilization serves GET /v1/admin/utilization: the full
// network-utilization snapshot (demand/capacity across the warm-serving and
// token-budget axes, plus a per-model breakdown and the bottleneck model).
// Admin-gated and read-only.
func (s *Owner) HandleAdminUtilization(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	httpx.WriteJSON(w, http.StatusOK, s.registry.NetworkUtilizationSnapshot())
}
