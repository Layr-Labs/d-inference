package reporting

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	pseudonym "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/pseudonym"
	"github.com/eigeninference/d-inference/coordinator/internal/api/reporting/ranking"
	windows "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/windows"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleLeaderboard returns the top N accounts ranked by earnings,
// tokens, or jobs. Pseudonymized — never exposes raw account IDs.
//
// GET /v1/leaderboard?metric=earnings|tokens|jobs&window=24h|7d|30d|all&limit=50
func (s *Owner) HandleLeaderboard(w http.ResponseWriter, r *http.Request) {
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
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"metric must be one of: earnings, tokens, jobs"))
		return
	}

	windowParam := q.Get("window")
	_, ok := windows.ParseLeaderboardWindow(windowParam)
	if !ok {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"window must be one of: 24h, 7d, 30d, all"))
		return
	}

	limit := 50
	if l, err := strconv.Atoi(q.Get("limit")); err == nil && l > 0 && l <= 200 {
		limit = l
	}

	var rows []store.LeaderboardRow
	var updatedAt string
	if s.analyticsSnapshotPath != "" {
		snapshot, ok := s.analyticsSnapshot.Get(time.Now())
		if !ok {
			analyticsUnavailable(w)
			return
		}
		rows = snapshot.Windows[windows.NetworkTotalsWindow(windowParam)].Leaderboards[metricParam]
		updatedAt = snapshot.AsOf.UTC().Format(time.RFC3339)
	} else {
		result, err := s.CachedLeaderboard(r.Context(), metric, windowParam)
		if err != nil {
			if r.Context().Err() != nil {
				return
			}
			w.Header().Set("Retry-After", strconv.Itoa(ranking.LeaderboardRetryAfter(err)))
			httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("service_unavailable",
				"leaderboard is temporarily unavailable"))
			return
		}
		rows, updatedAt = result.Rows, result.UpdatedAt
	}

	type entry struct {
		Rank                   int    `json:"rank"`
		Pseudonym              string `json:"pseudonym"`
		EarningsMicroUSD       int64  `json:"earnings_micro_usd"`
		WorkEarningsMicroUSD   int64  `json:"work_earnings_micro_usd"`
		RewardEarningsMicroUSD int64  `json:"reward_earnings_micro_usd"`
		Tokens                 int64  `json:"tokens"`
		Jobs                   int64  `json:"jobs"`
	}
	if len(rows) > limit {
		rows = rows[:limit]
	}
	entries := make([]entry, 0, len(rows))
	for i, r := range rows {
		entries = append(entries, entry{
			Rank:                   i + 1,
			Pseudonym:              pseudonym.Generate(r.AccountID),
			EarningsMicroUSD:       r.EarningsMicroUSD,
			WorkEarningsMicroUSD:   r.WorkEarningsMicroUSD,
			RewardEarningsMicroUSD: r.RewardEarningsMicroUSD,
			Tokens:                 r.Tokens,
			Jobs:                   r.Jobs,
		})
	}

	resp := map[string]any{
		"metric":     metricParam,
		"window":     windows.WindowParamOrDefault(windowParam),
		"entries":    entries,
		"updated_at": updatedAt,
	}
	body, err := json.Marshal(resp)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to encode response"))
		return
	}
	httpx.WriteCachedJSON(w, body)
}
