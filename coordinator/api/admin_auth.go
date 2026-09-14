package api

import (
	"crypto/subtle"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/auth"
)

// isAdminAuthorized checks if the request is from an admin.
// Accepts either Privy admin (email in admin list) OR EIGENINFERENCE_ADMIN_KEY.
func (s *Server) isAdminAuthorized(w http.ResponseWriter, r *http.Request) bool {
	// Check admin key first (no Privy needed).
	token := extractBearerToken(r)
	if token != "" && s.adminKey != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.adminKey)) == 1 {
		return true
	}

	// Check Privy admin.
	user := auth.UserFromContext(r.Context())
	if user != nil && s.isAdmin(user) {
		return true
	}

	writeJSON(w, http.StatusForbidden, errorResponse("forbidden", "admin access required"))
	return false
}

// handleAdminAuthInit handles POST /v1/admin/auth/init.
// Sends an OTP code to the given email via Privy. Used by the admin CLI.
func (s *Server) handleAdminAuthInit(w http.ResponseWriter, r *http.Request) {
	if s.privyAuth == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("not_configured", "Privy auth not configured"))
		return
	}

	var req struct {
		Email string `json:"email"`
	}
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}
	if req.Email == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email is required"))
		return
	}

	if err := s.privyAuth.InitEmailOTP(req.Email); err != nil {
		s.logger.Error("admin auth: OTP init failed", "email", req.Email, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("otp_error", "failed to send OTP: "+err.Error()))
		return
	}

	s.logger.Info("admin auth: OTP sent", "email", req.Email)
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "otp_sent",
		"email":  req.Email,
	})
}

// handleAdminAuthVerify handles POST /v1/admin/auth/verify.
// Verifies the OTP code and returns a Privy access token for admin use.
func (s *Server) handleAdminAuthVerify(w http.ResponseWriter, r *http.Request) {
	if s.privyAuth == nil {
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("not_configured", "Privy auth not configured"))
		return
	}

	var req struct {
		Email string `json:"email"`
		Code  string `json:"code"`
	}
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}
	if req.Email == "" || req.Code == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "email and code are required"))
		return
	}

	token, err := s.privyAuth.VerifyEmailOTP(req.Email, req.Code)
	if err != nil {
		s.logger.Warn("admin auth: OTP verification failed", "email", req.Email, "error", err)
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "OTP verification failed: "+err.Error()))
		return
	}

	s.logger.Info("admin auth: login successful", "email", req.Email)
	writeJSON(w, http.StatusOK, map[string]any{
		"token": token,
		"email": req.Email,
	})
}
