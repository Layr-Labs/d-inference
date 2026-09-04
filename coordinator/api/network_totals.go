package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// handleNetworkTotals returns aggregate network metrics for a given window.
//
// GET /v1/network/totals?window=24h|7d|30d|all
func (s *Server) handleNetworkTotals(w http.ResponseWriter, r *http.Request) {
	windowParam := r.URL.Query().Get("window")
	if _, ok := parseLeaderboardWindow(windowParam); !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"window must be one of: 24h, 7d, 30d, all"))
		return
	}

	window := networkTotalsWindow(windowParam)
	if cached, ok := s.readCache.Get(networkTotalsCacheKey(window)); ok {
		writeCachedJSON(w, cached)
		return
	}
	body, ok := s.getCachedEntry(s.networkTotalsEntry(window), networkTotalsCacheKey(window), func() ([]byte, error) { return s.computeNetworkTotals(window) })
	if !ok {
		// Nothing cached and the aggregate failed (typically the store
		// timeout): say so rather than serve a zero row as if it were data.
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable",
			"network totals are temporarily unavailable"))
		return
	}
	writeCachedJSON(w, body)
}

// networkTotalsWindows are the canonical windows the refresher keeps warm;
// the handler maps aliases (1d, lifetime, "") onto them.
var networkTotalsWindows = []string{"24h", "7d", "30d", "all"}

func networkTotalsWindow(param string) string {
	switch param {
	case "1d":
		return "24h"
	case "", "lifetime":
		return "all"
	}
	return param
}

func networkTotalsCacheKey(window string) string { return "network_totals:" + window }

// networkTotalsEntry returns the refresher state for one window.
func (s *Server) networkTotalsEntry(window string) *cacheRefresher {
	r := &s.networkTotalsRefresh
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.entries == nil {
		r.entries = make(map[string]*cacheRefresher, len(networkTotalsWindows))
	}
	entry := r.entries[window]
	if entry == nil {
		entry = &cacheRefresher{}
		r.entries[window] = entry
	}
	return entry
}

// refreshNetworkTotals computes one window's totals (coalesced) and caches
// them. A store error leaves the previously cached value in place — the
// statement scans provider_earnings three times and used to come back as an
// all-zero row on its 10 s timeout, which the handler then cached and served.
func (s *Server) refreshNetworkTotals(window string) ([]byte, bool) {
	return s.refreshCachedEntry(s.networkTotalsEntry(window), networkTotalsCacheKey(window), func() ([]byte, error) {
		return s.computeNetworkTotals(window)
	})
}

func (s *Server) computeNetworkTotals(window string) ([]byte, error) {
	since, ok := parseLeaderboardWindow(window)
	if !ok {
		return nil, fmt.Errorf("invalid network totals window: %s", window)
	}
	totals, err := s.store.NetworkTotals(since)
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

// runNetworkTotalsRefresher owns every network_totals:<window> entry with an
// injectable interval. The windows are computed one after another; all four
// were already requested continuously in production, so the cadence adds no
// load — it only removes the per-request misses and the cached zero rows.
func (s *Server) runNetworkTotalsRefresher(ctx context.Context, interval time.Duration) {
	s.runCacheRefreshLoop(ctx, interval, func() {
		for _, window := range networkTotalsWindows {
			if ctx.Err() != nil {
				return
			}
			s.refreshNetworkTotals(window)
		}
	})
}
