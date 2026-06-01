package api

import (
	"fmt"
	"net/http"
	"strconv"
	"time"
)

// handleNodeEarnings handles GET /v1/provider/node-earnings?provider_key=<key>&limit=50.
// Returns recent per-node earnings history plus lifetime aggregates for the node.
func (s *Server) handleNodeEarnings(w http.ResponseWriter, r *http.Request) {
	providerKey := r.URL.Query().Get("provider_key")
	if providerKey == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "provider_key query parameter is required"))
		return
	}

	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if parsed, err := strconv.Atoi(v); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > 1000 {
		limit = 1000
	}

	earnings, err := s.store.GetProviderEarnings(providerKey, limit)
	if err != nil {
		s.logger.Error("get provider earnings failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	summary, err := s.store.GetProviderEarningsSummary(providerKey)
	if err != nil {
		s.logger.Error("get provider earnings summary failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings summary"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"provider_key":    providerKey,
		"earnings":        earnings,
		"total_micro_usd": summary.TotalMicroUSD,
		"total_usd":       fmt.Sprintf("%.6f", float64(summary.TotalMicroUSD)/1_000_000),
		"count":           summary.Count,
		"recent_count":    len(earnings),
		"history_limit":   limit,
	})
}

// handleAccountEarnings handles GET /v1/provider/account-earnings?limit=50.
// Returns recent earnings history, lifetime aggregates, and current account balance
// for the authenticated provider account.
// Cached for 20s per account — dashboard polls this frequently.
func (s *Server) handleAccountEarnings(w http.ResponseWriter, r *http.Request) {
	accountID := s.resolveAccountID(r)

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
		writeCachedJSON(w, cached)
		return
	}

	earnings, err := s.store.GetAccountEarnings(accountID, limit)
	if err != nil {
		s.logger.Error("get account earnings failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		s.logger.Error("get account earnings summary failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings summary"))
		return
	}

	availableBalance, withdrawableBalance := s.store.GetBalanceWithWithdrawable(accountID)

	s.writeCachedJSONResult(w, cacheKey, 20*time.Second, map[string]any{
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
	}, "failed to marshal earnings")
}
