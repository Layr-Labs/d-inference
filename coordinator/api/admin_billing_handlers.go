package api

import (
	"fmt"
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// handleAdminPricing handles PUT /v1/admin/pricing.
// Sets platform default prices for a model. Requires a Privy account with
// an admin email. These defaults apply to all users who haven't set custom prices.
func (s *Server) handleAdminPricing(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`
		OutputPrice int64  `json:"output_price"`
	}
	if !decodeJSONBody(w, r, &req) {
		return
	}
	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return
	}
	if req.InputPrice <= 0 || req.OutputPrice <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "input_price and output_price must be positive"))
		return
	}

	// Store under the special "platform" account.
	if err := s.store.SetModelPrice("platform", req.Model, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("admin pricing: set failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to set price"))
		return
	}

	s.logger.Info("admin: platform price updated",
		"model", req.Model,
		"input_price", req.InputPrice,
		"output_price", req.OutputPrice,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "platform_default_updated",
		"model":        req.Model,
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
		"input_usd":    fmt.Sprintf("$%.4f per 1M tokens", float64(req.InputPrice)/1_000_000),
		"output_usd":   fmt.Sprintf("$%.4f per 1M tokens", float64(req.OutputPrice)/1_000_000),
	})
}

// handleAdminSetUserRole handles PUT /v1/admin/users/role.
// Grants or clears an account role (e.g. RoleService for OpenRouter). Admin only.
func (s *Server) handleAdminSetUserRole(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		AccountID string `json:"account_id"`
		Role      string `json:"role"`
	}
	if !decodeJSONBody(w, r, &req) {
		return
	}
	if req.AccountID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "account_id is required", withParam("account_id")))
		return
	}
	// Only known roles are accepted. "" clears the role back to a normal account.
	if req.Role != "" && req.Role != store.RoleService {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			fmt.Sprintf("invalid role %q — allowed: %q or \"\"", req.Role, store.RoleService), withParam("role")))
		return
	}

	if err := s.store.SetUserRole(req.AccountID, req.Role); err != nil {
		s.logger.Error("admin set role: failed", "account_id", req.AccountID, "error", err)
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "user not found or update failed"))
		return
	}

	s.logger.Info("admin: user role updated", "account_id", req.AccountID, "role", req.Role)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":     "role_updated",
		"account_id": req.AccountID,
		"role":       req.Role,
	})
}

// handleAdminSetUserPlatformFee handles PUT /v1/admin/users/platform-fee.
// Sets a per-account platform fee override (0–100). Omit platform_fee_percent
// (or send null) to clear the override and fall back to the global default.
// Admin only.
func (s *Server) handleAdminSetUserPlatformFee(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		AccountID          string `json:"account_id"`
		PlatformFeePercent *int64 `json:"platform_fee_percent"`
	}
	if !decodeJSONBody(w, r, &req) {
		return
	}
	if req.AccountID == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "account_id is required", withParam("account_id")))
		return
	}
	if req.PlatformFeePercent != nil && (*req.PlatformFeePercent < 0 || *req.PlatformFeePercent > 100) {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"platform_fee_percent must be between 0 and 100", withParam("platform_fee_percent")))
		return
	}

	if err := s.store.SetUserPlatformFeePercent(req.AccountID, req.PlatformFeePercent); err != nil {
		s.logger.Error("admin set platform fee: failed", "account_id", req.AccountID, "error", err)
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "user not found or update failed"))
		return
	}

	resp := map[string]any{
		"status":     "platform_fee_updated",
		"account_id": req.AccountID,
	}
	if req.PlatformFeePercent != nil {
		resp["platform_fee_percent"] = *req.PlatformFeePercent
	} else {
		resp["platform_fee_percent"] = nil
		resp["note"] = "override cleared — using global default"
	}
	s.logger.Info("admin: user platform fee updated", "account_id", req.AccountID, "fee", req.PlatformFeePercent)
	writeJSON(w, http.StatusOK, resp)
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
	if !decodeJSONBody(w, r, &req) {
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
	amountMicroUSD := payments.USDToMicro(amountFloat)

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
	if !decodeJSONBody(w, r, &req) {
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
	amountMicroUSD := payments.USDToMicro(amountFloat)

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
