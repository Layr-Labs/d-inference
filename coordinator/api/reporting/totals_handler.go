package reporting

import (
	"net/http"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	totalsview "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/totalsview"
	windows "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/windows"
)

// handleNetworkTotals returns aggregate network metrics for a given window.
//
// GET /v1/network/totals?window=24h|7d|30d|all
func (s *Owner) HandleNetworkTotals(w http.ResponseWriter, r *http.Request) {
	windowParam := r.URL.Query().Get("window")
	if _, ok := windows.ParseLeaderboardWindow(windowParam); !ok {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"window must be one of: 24h, 7d, 30d, all"))
		return
	}

	window := windows.NetworkTotalsWindow(windowParam)
	if s.analyticsSnapshotPath != "" {
		s.archivedNetworkTotals(w, window)
		return
	}
	if cached, ok := s.readCache.Get(totalsview.NetworkTotalsCacheKey(window)); ok {
		httpx.WriteCachedJSON(w, cached)
		return
	}
	body, ok := s.CachedNetworkTotals(window)
	if !ok {
		// Nothing cached and the aggregate failed (typically the store
		// timeout): say so rather than serve a zero row as if it were data.
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("service_unavailable",
			"network totals are temporarily unavailable"))
		return
	}
	httpx.WriteCachedJSON(w, body)
}
