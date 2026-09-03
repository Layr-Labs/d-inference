package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// parseLeaderboardWindow returns the cutoff time for the requested
// window. Empty string and "all" return zero time (all-time).
func parseLeaderboardWindow(s string) (time.Time, bool) {
	now := time.Now()
	switch s {
	case "", "all", "lifetime":
		return time.Time{}, true
	case "24h", "1d":
		return now.Add(-24 * time.Hour), true
	case "7d":
		return now.Add(-7 * 24 * time.Hour), true
	case "30d":
		return now.Add(-30 * 24 * time.Hour), true
	}
	return time.Time{}, false
}

// handleLeaderboard returns the top N accounts ranked by earnings,
// tokens, or jobs. Pseudonymized — never exposes raw account IDs.
//
// GET /v1/leaderboard?metric=earnings|tokens|jobs&window=24h|7d|30d|all&limit=50
func (s *Server) handleLeaderboard(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	metricParam := q.Get("metric")
	if metricParam == "" {
		metricParam = "earnings"
	}
	var metric store.LeaderboardMetric
	switch metricParam {
	case "earnings":
		metric = store.LeaderboardEarnings
	case "tokens":
		metric = store.LeaderboardTokens
	case "jobs":
		metric = store.LeaderboardJobs
	default:
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"metric must be one of: earnings, tokens, jobs"))
		return
	}

	windowParam := q.Get("window")
	since, ok := parseLeaderboardWindow(windowParam)
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"window must be one of: 24h, 7d, 30d, all"))
		return
	}

	limit := 50
	if l, err := strconv.Atoi(q.Get("limit")); err == nil && l > 0 && l <= 200 {
		limit = l
	}

	cacheKey := fmt.Sprintf("leaderboard:%s:%s:%d", metric, windowParam, limit)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	rows := s.store.Leaderboard(metric, since, limit)

	type entry struct {
		Rank                   int    `json:"rank"`
		Pseudonym              string `json:"pseudonym"`
		EarningsMicroUSD       int64  `json:"earnings_micro_usd"`
		WorkEarningsMicroUSD   int64  `json:"work_earnings_micro_usd"`
		RewardEarningsMicroUSD int64  `json:"reward_earnings_micro_usd"`
		Tokens                 int64  `json:"tokens"`
		Jobs                   int64  `json:"jobs"`
	}
	entries := make([]entry, 0, len(rows))
	for i, r := range rows {
		entries = append(entries, entry{
			Rank:                   i + 1,
			Pseudonym:              pseudonym(r.AccountID),
			EarningsMicroUSD:       r.EarningsMicroUSD,
			WorkEarningsMicroUSD:   r.WorkEarningsMicroUSD,
			RewardEarningsMicroUSD: r.RewardEarningsMicroUSD,
			Tokens:                 r.Tokens,
			Jobs:                   r.Jobs,
		})
	}

	resp := map[string]any{
		"metric":     metricParam,
		"window":     windowParamOrDefault(windowParam),
		"entries":    entries,
		"updated_at": time.Now().UTC().Format(time.RFC3339),
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode response"))
		return
	}
	s.readCache.Set(cacheKey, body, 5*time.Minute)
	writeCachedJSON(w, body)
}

func windowParamOrDefault(s string) string {
	if s == "" {
		return "all"
	}
	return s
}

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
	body, ok := s.refreshNetworkTotals(window)
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
	since, ok := parseLeaderboardWindow(window)
	if !ok {
		return nil, false
	}
	return s.refreshCachedEntry(s.networkTotalsEntry(window), networkTotalsCacheKey(window), func() ([]byte, bool, error) {
		totals, err := s.store.NetworkTotals(since)
		if err != nil {
			return nil, false, err
		}
		body, err := json.Marshal(map[string]any{
			"window":                    window,
			"earnings_micro_usd":        totals.EarningsMicroUSD,
			"work_earnings_micro_usd":   totals.WorkEarningsMicroUSD,
			"reward_earnings_micro_usd": totals.RewardEarningsMicroUSD,
			"tokens":                    totals.Tokens,
			"jobs":                      totals.Jobs,
			"active_accounts":           totals.ActiveAccounts,
			"updated_at":                time.Now().UTC().Format(time.RFC3339),
		})
		return body, false, err
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
