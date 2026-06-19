package api

import "net/http"

// handleAdminUtilization serves GET /v1/admin/utilization: the full
// network-utilization snapshot (demand/capacity across the warm-serving and
// token-budget axes, plus a per-model breakdown and the bottleneck model).
// Admin-gated and read-only.
func (s *Server) handleAdminUtilization(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, s.registry.NetworkUtilizationSnapshot())
}
