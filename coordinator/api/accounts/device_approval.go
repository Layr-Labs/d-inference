package accounts

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/auth"
)

// ApproveDevice approves a device code, linking it to the authenticated user's account.
// POST /v1/device/approve
// Requires Privy auth — the user must be logged in.
func (s *Controller) ApproveDevice(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpresponse.WriteJSON(w, http.StatusUnauthorized, httpresponse.ErrorBody("auth_error", "Privy authentication required"))
		return
	}

	var req struct {
		UserCode string `json:"user_code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserCode == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request", "user_code is required"))
		return
	}

	// Normalize: uppercase, trim spaces.
	userCode := strings.ToUpper(strings.TrimSpace(req.UserCode))

	dc, err := s.store().GetDeviceCodeByUserCode(userCode)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("invalid_code", "device code not found — check the code and try again"))
		return
	}

	if time.Now().After(dc.ExpiresAt) {
		httpresponse.WriteJSON(w, http.StatusGone, httpresponse.ErrorBody("expired_code", "this code has expired — run 'darkbloom login' again"))
		return
	}

	if dc.Status != "pending" {
		httpresponse.WriteJSON(w, http.StatusConflict, httpresponse.ErrorBody("already_used", "this code has already been used"))
		return
	}

	if err := s.store().ApproveDeviceCode(dc.DeviceCode, user.AccountID); err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to approve device"))
		return
	}

	s.logger.Info("device approved",
		"user_code", userCode,
		"account_id", user.AccountID,
		"email", user.Email,
	)

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
		"status":  "approved",
		"message": "Device linked successfully. Your provider will connect to your account shortly.",
	})
}
