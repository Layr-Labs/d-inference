package api

import "net/http"

// handlePlatformRevenue serves GET /v1/admin/platform-revenue: total platform
// fees collected across all time in micro-USD. Admin-gated, read-only.
func (s *Server) handlePlatformRevenue(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	total := s.store.GetPlatformRevenue(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"total_platform_fees_micro_usd": total,
	})
}
