package reporting

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// handleStats returns aggregate platform statistics for the frontend dashboard.
//
// The response is served from the stats:v1 read-cache entry, which the
// refresher recomputes every statsRefreshInterval. A handler only computes on
// a cold start (no entry at all), and concurrent cold misses share one
// computation.
func (s *Owner) HandleStats(w http.ResponseWriter, r *http.Request) {
	body, ok := s.CachedStats()
	if !ok {
		// Nothing cached and the computation could not produce a body (or a
		// coalesced computation failed for this waiter).
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("service_unavailable", "stats are temporarily unavailable"))
		return
	}
	httpx.WriteCachedJSON(w, body)
}
