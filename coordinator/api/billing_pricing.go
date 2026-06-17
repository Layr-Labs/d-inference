package api

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// --- Pricing ---

// handleGetPricing handles GET /v1/pricing.
// Public endpoint — returns platform default prices. Also overlays platform
// DB overrides (set via admin endpoint).
func (s *Server) handleGetPricing(w http.ResponseWriter, r *http.Request) {
	type priceEntry struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`  // micro-USD per 1M tokens
		OutputPrice int64  `json:"output_price"` // micro-USD per 1M tokens
		InputUSD    string `json:"input_usd"`
		OutputUSD   string `json:"output_usd"`
	}

	// All model prices come from the database (set via PUT /v1/admin/pricing).
	platformPrices := s.store.ListModelPrices("platform")
	prices := make([]priceEntry, 0, len(platformPrices))
	for _, mp := range platformPrices {
		prices = append(prices, priceEntry{
			Model:       mp.Model,
			InputPrice:  mp.InputPrice,
			OutputPrice: mp.OutputPrice,
			InputUSD:    fmt.Sprintf("$%.4f", float64(mp.InputPrice)/1_000_000),
			OutputUSD:   fmt.Sprintf("$%.4f", float64(mp.OutputPrice)/1_000_000),
		})
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"prices":                prices,
		"fallback_input_price":  payments.DefaultInputPricePerMillion,
		"fallback_output_price": payments.DefaultOutputPricePerMillion,
		"fallback_input_usd":    fmt.Sprintf("$%.4f", float64(payments.DefaultInputPricePerMillion)/1_000_000),
		"fallback_output_usd":   fmt.Sprintf("$%.4f", float64(payments.DefaultOutputPricePerMillion)/1_000_000),
	})
}

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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
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

// handleSetPricing handles PUT /v1/pricing.
// Providers set custom prices for models they serve. Requires Privy auth.
func (s *Server) handleSetPricing(w http.ResponseWriter, r *http.Request) {
	if s.requirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Model       string `json:"model"`
		InputPrice  int64  `json:"input_price"`
		OutputPrice int64  `json:"output_price"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return
	}
	if req.InputPrice <= 0 || req.OutputPrice <= 0 {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "input_price and output_price must be positive (micro-USD per 1M tokens)"))
		return
	}

	accountID := s.resolveAccountID(r)
	if err := s.store.SetModelPrice(accountID, req.Model, req.InputPrice, req.OutputPrice); err != nil {
		s.logger.Error("pricing: set failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to set price"))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status":       "updated",
		"model":        req.Model,
		"input_price":  req.InputPrice,
		"output_price": req.OutputPrice,
		"input_usd":    fmt.Sprintf("$%.4f per 1M tokens", float64(req.InputPrice)/1_000_000),
		"output_usd":   fmt.Sprintf("$%.4f per 1M tokens", float64(req.OutputPrice)/1_000_000),
	})
}

// handleDeletePricing handles DELETE /v1/pricing.
// Removes a custom price override, reverting to platform defaults.
func (s *Server) handleDeletePricing(w http.ResponseWriter, r *http.Request) {
	if s.requirePrivyUser(w, r) == nil {
		return
	}
	var req struct {
		Model string `json:"model"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Model == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "model is required", withParam("model")))
		return
	}

	accountID := s.resolveAccountID(r)
	if err := s.store.DeleteModelPrice(accountID, req.Model); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"status": "deleted",
		"model":  req.Model,
	})
}

// --- Payment Methods ---

func (s *Server) handleBillingMethods(w http.ResponseWriter, r *http.Request) {
	if s.billing == nil {
		writeJSON(w, http.StatusOK, map[string]any{"methods": []any{}})
		return
	}
	methods := s.billing.SupportedMethods()
	resp := map[string]any{"methods": methods}
	if s.billing.Referral() != nil {
		resp["referral"] = map[string]any{
			"enabled":       true,
			"share_percent": s.billing.Referral().SharePercent(),
		}
	}
	writeJSON(w, http.StatusOK, resp)
}
