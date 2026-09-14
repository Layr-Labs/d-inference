package billing

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// AdminSetUserRole handles PUT /v1/admin/users/role.
// Grants or clears an account role (e.g. RoleService for OpenRouter). Admin only.
func (s *Controller) AdminSetUserRole(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	var req struct {
		AccountID string `json:"account_id"`
		Role      string `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.AccountID == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "account_id is required", httpresponse.WithParam("account_id")))
		return
	}
	// Only known roles are accepted. "" clears the role back to a normal account.
	if req.Role != "" && req.Role != store.RoleService {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			fmt.Sprintf("invalid role %q — allowed: %q or \"\"", req.Role, store.RoleService), httpresponse.WithParam("role")))
		return
	}

	if err := s.store.SetUserRole(req.AccountID, req.Role); err != nil {
		s.logger.Error("admin set role: failed", "account_id", req.AccountID, "error", err)
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "user not found or update failed"))
		return
	}

	s.logger.Info("admin: user role updated", "account_id", req.AccountID, "role", req.Role)
	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status":     "role_updated",
		"account_id": req.AccountID,
		"role":       req.Role,
	})
}

// AdminSetUserPlatformFee handles PUT /v1/admin/users/platform-fee.
// Sets a per-account platform fee override (0–100). Omit platform_fee_percent
// (or send null) to clear the override and fall back to the global default.
// Admin only.
func (s *Controller) AdminSetUserPlatformFee(w http.ResponseWriter, r *http.Request) {
	if !s.authorizeAdmin(w, r) {
		return
	}

	var req struct {
		AccountID          string `json:"account_id"`
		PlatformFeePercent *int64 `json:"platform_fee_percent"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.AccountID == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error", "account_id is required", httpresponse.WithParam("account_id")))
		return
	}
	if req.PlatformFeePercent != nil && (*req.PlatformFeePercent < 0 || *req.PlatformFeePercent > 100) {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request_error",
			"platform_fee_percent must be between 0 and 100", httpresponse.WithParam("platform_fee_percent")))
		return
	}

	if err := s.store.SetUserPlatformFeePercent(req.AccountID, req.PlatformFeePercent); err != nil {
		s.logger.Error("admin set platform fee: failed", "account_id", req.AccountID, "error", err)
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "user not found or update failed"))
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
	httpresponse.WriteJSON(w, http.StatusOK, resp)
}
