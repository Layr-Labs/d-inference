package billing

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// handleAccountEarnings handles GET /v1/provider/account-earnings?limit=50.
// Returns recent earnings history, lifetime aggregates, and current account balance
// for the authenticated provider account.
// Cached for 20s per account — dashboard polls this frequently.
func (s *Owner) HandleAccountEarnings(w http.ResponseWriter, r *http.Request) {
	accountID := access.ResolveAccountID(r)

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 1000 {
		limit = 1000
	}

	cacheKey := "account-earnings:" + accountID + ":" + strconv.Itoa(limit)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		httpx.WriteCachedJSON(w, cached)
		return
	}

	earnings, err := s.store.GetAccountEarnings(accountID, limit)
	if err != nil {
		s.logger.Error("get account earnings failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		s.logger.Error("get account earnings summary failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to fetch earnings summary"))
		return
	}

	availableBalance, withdrawableBalance := s.store.GetBalanceWithWithdrawable(accountID)

	body, err := json.Marshal(map[string]any{
		"account_id":                     accountID,
		"earnings":                       earnings,
		"total_micro_usd":                summary.TotalMicroUSD,
		"total_usd":                      fmt.Sprintf("%.6f", float64(summary.TotalMicroUSD)/1_000_000),
		"count":                          summary.Count,
		"recent_count":                   len(earnings),
		"history_limit":                  limit,
		"available_balance_micro_usd":    availableBalance,
		"available_balance_usd":          fmt.Sprintf("%.6f", float64(availableBalance)/1_000_000),
		"withdrawable_balance_micro_usd": withdrawableBalance,
		"withdrawable_balance_usd":       fmt.Sprintf("%.6f", float64(withdrawableBalance)/1_000_000),
	})
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to marshal earnings"))
		return
	}
	s.readCache.Set(cacheKey, body, 20*time.Second)
	httpx.WriteCachedJSON(w, body)
}
