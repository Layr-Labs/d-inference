package network

import (
	"context"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

const statsCacheKey = "stats:v1"

// Stats returns aggregate platform statistics for the frontend dashboard.
//
// The response is served from the stats:v1 read-cache entry, which the
// refresher recomputes every statsRefreshInterval. A handler only computes on
// a cold start (no entry at all), and concurrent cold misses share one
// computation.
func (s *Controller) Stats(w http.ResponseWriter, r *http.Request) {
	if cached, ok := s.readCache().Get(statsCacheKey); ok {
		httpresponse.WriteCachedJSON(w, cached)
		return
	}
	body, ok := s.getCachedEntry(&s.statsRefresh, statsCacheKey, s.computeStats)
	if !ok {
		// Nothing cached and the computation could not produce a body (or a
		// coalesced computation failed for this waiter).
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("service_unavailable", "stats are temporarily unavailable"))
		return
	}
	httpresponse.WriteCachedJSON(w, body)
}

// runStatsRefresher owns the stats:v1 entry with an injectable interval.
func (s *Controller) runStatsRefresher(ctx context.Context, interval time.Duration) {
	s.runCacheRefreshLoop(ctx, interval, func() { s.refreshStats() })
}

// refreshStats recomputes stats, retaining an unexpired success on failure.
func (s *Controller) refreshStats() ([]byte, bool) {
	return s.refreshCachedEntry(&s.statsRefresh, statsCacheKey, s.computeStats)
}
