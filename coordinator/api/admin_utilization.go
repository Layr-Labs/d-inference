package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// handleAdminUtilization serves GET /v1/admin/utilization: the full
// network-utilization snapshot (demand/capacity across the warm-serving and
// token-budget axes, plus a per-model breakdown and the bottleneck model).
// Admin-gated and read-only.
func (s *Server) handleAdminUtilization(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	type utilizationResponse struct {
		registry.NetworkUtilization
		// ModelPools is the DAR-345 pool/assignment + co-residency audit, surfaced
		// alongside the demand/capacity snapshot so admins can answer pool sizes,
		// who-serves-what, and co-residency in one call.
		ModelPools registry.ModelPoolReport `json:"model_pools"`
	}
	writeJSON(w, http.StatusOK, utilizationResponse{
		NetworkUtilization: s.registry.NetworkUtilizationSnapshot(),
		ModelPools:         s.registry.ModelPoolReport(),
	})
}
