package network

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// Totals returns aggregate network metrics for a given window.
//
// GET /v1/network/totals?window=24h|7d|30d|all
func (s *Controller) Totals(w http.ResponseWriter, r *http.Request) {
	windowParam := r.URL.Query().Get("window")
	if _, ok := parseLeaderboardWindow(windowParam); !ok {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			"window must be one of: 24h, 7d, 30d, all"))
		return
	}

	window := networkTotalsWindow(windowParam)
	if cached, ok := s.readCache().Get(networkTotalsCacheKey(window)); ok {
		httpresponse.WriteCachedJSON(w, cached)
		return
	}
	body, ok := s.getCachedEntry(s.networkTotalsEntry(window), networkTotalsCacheKey(window), func() ([]byte, error) { return s.computeNetworkTotals(window) })
	if !ok {
		// Nothing cached and the aggregate failed (typically the store
		// timeout): say so rather than serve a zero row as if it were data.
		httpresponse.WriteJSON(w, http.StatusServiceUnavailable, httpresponse.ErrorBody("service_unavailable",
			"network totals are temporarily unavailable"))
		return
	}
	httpresponse.WriteCachedJSON(w, body)
}

func (s *Controller) computeNetworkTotals(window string) ([]byte, error) {
	// Cold fills for distinct windows share the background loop's one-query
	// concurrency bound; each transaction raises work_mem for several scans.
	s.networkTotalsRefresh.queryMu.Lock()
	defer s.networkTotalsRefresh.queryMu.Unlock()
	since, ok := parseLeaderboardWindow(window)
	if !ok {
		return nil, fmt.Errorf("invalid network totals window: %s", window)
	}
	totals, err := s.store().NetworkTotals(since)
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{
		"window":                    window,
		"earnings_micro_usd":        totals.EarningsMicroUSD,
		"work_earnings_micro_usd":   totals.WorkEarningsMicroUSD,
		"reward_earnings_micro_usd": totals.RewardEarningsMicroUSD,
		"tokens":                    totals.Tokens,
		"jobs":                      totals.Jobs,
		"active_accounts":           totals.ActiveAccounts,
		"updated_at":                time.Now().UTC().Format(time.RFC3339),
	})
}
