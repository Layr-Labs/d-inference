package api

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/coordinator/internal/store"
)

// pseudonym returns a stable, opaque short ID for an account. Uses
// SHA-256 of the account UUID truncated to 8 hex chars (~32 bits).
// Collisions across the global account space are theoretically possible
// at very high volumes (>~65k accounts) but the leaderboard only shows
// the top N so collisions matter only inside that window — users can
// disambiguate via context.
func pseudonym(accountID string) string {
	if accountID == "" {
		return "anon"
	}
	sum := sha256.Sum256([]byte(accountID))
	return "node-" + hex.EncodeToString(sum[:4])
}

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
		writeCachedJSON(w, http.StatusOK, cached)
		return
	}

	rows := s.store.Leaderboard(metric, since, limit)

	type entry struct {
		Rank             int    `json:"rank"`
		Pseudonym        string `json:"pseudonym"`
		EarningsMicroUSD int64  `json:"earnings_micro_usd"`
		Tokens           int64  `json:"tokens"`
		Jobs             int64  `json:"jobs"`
	}
	entries := make([]entry, 0, len(rows))
	for i, r := range rows {
		entries = append(entries, entry{
			Rank:             i + 1,
			Pseudonym:        pseudonym(r.AccountID),
			EarningsMicroUSD: r.EarningsMicroUSD,
			Tokens:           r.Tokens,
			Jobs:             r.Jobs,
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
	writeCachedJSON(w, http.StatusOK, body)
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
	since, ok := parseLeaderboardWindow(windowParam)
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"window must be one of: 24h, 7d, 30d, all"))
		return
	}

	cacheKey := "network_totals:" + windowParamOrDefault(windowParam)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, http.StatusOK, cached)
		return
	}

	totals := s.store.NetworkTotals(since)
	resp := map[string]any{
		"window":             windowParamOrDefault(windowParam),
		"earnings_micro_usd": totals.EarningsMicroUSD,
		"tokens":             totals.Tokens,
		"jobs":               totals.Jobs,
		"active_accounts":    totals.ActiveAccounts,
		"updated_at":         time.Now().UTC().Format(time.RFC3339),
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode response"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, http.StatusOK, body)
}
