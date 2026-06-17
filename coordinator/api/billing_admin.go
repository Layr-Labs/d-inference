package api

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleModelCatalog handles GET /v1/models/catalog.
// Public endpoint — returns active models for providers and the install script.
// Cached for 60s — the underlying DB query is fast but this endpoint is hit
// by every provider heartbeat and install script poll.
func modelCatalogCacheKey(typeFilter string, includeAliases bool) string {
	return "models:catalog:type=" + typeFilter + ":include_aliases=" + strconv.FormatBool(includeAliases)
}

func (s *Server) handleModelCatalog(w http.ResponseWriter, r *http.Request) {
	// Optional filter: ?type=text
	typeFilter := strings.TrimSpace(strings.ToLower(r.URL.Query().Get("type")))
	if typeFilter != "" && typeFilter != "text" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "unsupported catalog type", withParam("type")))
		return
	}
	includeAliases := r.URL.Query().Get("include_aliases") == "1" || strings.EqualFold(r.URL.Query().Get("include_aliases"), "true")

	cacheKey := modelCatalogCacheKey(typeFilter, includeAliases)
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	registryRows, err := s.store.ListActiveModelRegistryWithError()
	if err != nil {
		s.logger.Error("model registry: failed to list active models", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch model catalog"))
		return
	}
	// The catalog is text-only today; an explicit non-text filter yields nothing.
	models := make([]map[string]any, 0, len(registryRows))
	if typeFilter == "" || typeFilter == "text" {
		for i := range registryRows {
			models = append(models, catalogModelFromRegistryRecord(&registryRows[i]))
		}
	}
	response := map[string]any{"models": models}
	if includeAliases {
		aliases, err := s.store.ListModelAliases()
		if err != nil {
			s.logger.Warn("model registry: failed to list aliases for catalog response", "error", err)
		} else {
			response["aliases"] = catalogAliasesForResponse(models, aliases)
		}
	}

	body, err := json.Marshal(response)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to marshal catalog"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// handleAdminCredit handles POST /v1/admin/credit.
// Credits a user's non-withdrawable balance by email.
func (s *Server) handleAdminCredit(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Email     string `json:"email"`
		AmountUSD string `json:"amount_usd"`
		Note      string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Email == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email is required"))
		return
	}
	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}
	amountMicroUSD := int64(amountFloat * 1_000_000)

	user, err := s.store.GetUserByEmail(req.Email)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no user found with email: "+req.Email))
		return
	}

	ref := "admin_credit"
	if req.Note != "" {
		ref = "admin_credit:" + req.Note
	}
	if err := s.store.Credit(user.AccountID, amountMicroUSD, store.LedgerAdminCredit, ref); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to credit: "+err.Error()))
		return
	}

	s.logger.Info("admin credit applied",
		"email", req.Email,
		"account_id", user.AccountID,
		"amount_micro_usd", amountMicroUSD,
		"note", req.Note,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"account_id":    user.AccountID,
		"email":         user.Email,
		"credited_usd":  amountFloat,
		"withdrawable":  false,
		"balance_after": float64(s.store.GetBalance(user.AccountID)) / 1_000_000,
	})
}

// handleAdminReward handles POST /v1/admin/reward.
// Credits a user's withdrawable balance by email (treated as earnings).
func (s *Server) handleAdminReward(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Email     string `json:"email"`
		AmountUSD string `json:"amount_usd"`
		Note      string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Email == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email is required"))
		return
	}
	amountFloat, err := strconv.ParseFloat(req.AmountUSD, 64)
	if err != nil || amountFloat <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "amount_usd must be a positive number"))
		return
	}
	amountMicroUSD := int64(amountFloat * 1_000_000)

	user, err := s.store.GetUserByEmail(req.Email)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no user found with email: "+req.Email))
		return
	}

	ref := "admin_reward"
	if req.Note != "" {
		ref = "admin_reward:" + req.Note
	}
	if err := s.store.CreditWithdrawable(user.AccountID, amountMicroUSD, store.LedgerAdminReward, ref); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to reward: "+err.Error()))
		return
	}

	s.logger.Info("admin reward applied",
		"email", req.Email,
		"account_id", user.AccountID,
		"amount_micro_usd", amountMicroUSD,
		"note", req.Note,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":                 true,
		"account_id":         user.AccountID,
		"email":              user.Email,
		"rewarded_usd":       amountFloat,
		"withdrawable":       true,
		"balance_after":      float64(s.store.GetBalance(user.AccountID)) / 1_000_000,
		"withdrawable_after": float64(s.store.GetWithdrawableBalance(user.AccountID)) / 1_000_000,
	})
}
