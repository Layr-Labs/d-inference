package access

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// HandleAdminAuthInit handles POST /v1/admin/auth/init.
// Sends an OTP code to the given email via Privy. Used by the admin CLI.
func (s *Owner) HandleAdminAuthInit(w http.ResponseWriter, r *http.Request) {
	if s.privyAuth == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("not_configured", "Privy auth not configured"))
		return
	}

	var req struct {
		Email string `json:"email"`
	}
	if !httpx.DecodeCappedJSON(w, r, s.controlPlaneBodyBytes, &req) {
		return
	}
	if req.Email == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "email is required"))
		return
	}

	if err := s.privyAuth.InitEmailOTP(req.Email); err != nil {
		s.logger.Error("admin auth: OTP init failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("otp_error", "failed to send OTP: "+err.Error()))
		return
	}

	s.logger.Info("admin auth: OTP sent")
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"status": "otp_sent",
		"email":  req.Email,
	})
}

// HandleAdminAuthVerify handles POST /v1/admin/auth/verify.
// Verifies the OTP code and returns a Privy access token for admin use.
func (s *Owner) HandleAdminAuthVerify(w http.ResponseWriter, r *http.Request) {
	if s.privyAuth == nil {
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("not_configured", "Privy auth not configured"))
		return
	}

	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if !httpx.DecodeCappedJSON(w, r, s.controlPlaneBodyBytes, &req) {
		return
	}
	if req.Email == "" || req.Code == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error", "email and code are required"))
		return
	}

	token, err := s.privyAuth.VerifyEmailOTP(req.Email, req.Code)
	if err != nil {
		s.logger.Warn("admin auth: OTP verification failed", "error", err)
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "OTP verification failed: "+err.Error()))
		return
	}

	s.logger.Info("admin auth: login successful")
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"token": token,
		"email": req.Email,
	})
}
