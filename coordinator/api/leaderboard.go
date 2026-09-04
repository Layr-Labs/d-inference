package api

import (
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

	// Served from the refresher-owned entry (stats_refresher.go); a miss
	// recomputes through the same coalesced refresh, and a failed refresh is
	// reported rather than cached as an all-zero network.
	window := windowParamOrDefault(windowParam)
	if cached, ok := s.readCacheGet(networkTotalsCacheKey(window)); ok {
		writeCachedJSON(w, cached)
		return
	}
	body, err := s.refreshNetworkTotals(window)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("service_unavailable", "network totals are not available yet"))
		return
	}
	writeCachedJSON(w, body)
}

// buildNetworkTotalsBody computes the /v1/network/totals body for one window
// (a value windowParamOrDefault returns). A store error means no usable
// result: the caller keeps its previous value.
func (s *Server) buildNetworkTotalsBody(window string) ([]byte, error) {
	since, ok := parseLeaderboardWindow(window)
	if !ok {
		return nil, fmt.Errorf("network totals: unknown window %q", window)
	}
	totals, err := s.store.NetworkTotals(since)
	if err != nil {
		return nil, err
	}
	resp := map[string]any{
		"window":                    window,
		"earnings_micro_usd":        totals.EarningsMicroUSD,
		"work_earnings_micro_usd":   totals.WorkEarningsMicroUSD,
		"reward_earnings_micro_usd": totals.RewardEarningsMicroUSD,
		"tokens":                    totals.Tokens,
		"jobs":                      totals.Jobs,
		"active_accounts":           totals.ActiveAccounts,
		"updated_at":                time.Now().UTC().Format(time.RFC3339),
	}
	body, err := json.Marshal(resp)
	if err != nil {
		return nil, fmt.Errorf("network totals: encode: %w", err)
	}
	return body, nil
}
