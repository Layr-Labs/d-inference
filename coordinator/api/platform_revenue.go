package api

import (
	"encoding/json"
	"net/http"
	"time"
)

const platformRevenueCacheTTL = 10 * time.Minute

// handlePlatformRevenue serves GET /v1/admin/platform-revenue: total platform
// fees collected across all time in micro-USD. Admin-gated, read-only.
// Cached for 10 minutes — the underlying ledger query is cheap (<5ms) but
// this is an admin endpoint with no need for real-time precision.
func (s *Server) handlePlatformRevenue(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	const cacheKey = "platform_revenue:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}
	total := s.store.GetPlatformRevenue(r.Context())
	resp := map[string]any{
		"total_platform_fees_micro_usd": total,
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode"))
		return
	}
	s.readCache.Set(cacheKey, body, platformRevenueCacheTTL)
	writeCachedJSON(w, body)
}
