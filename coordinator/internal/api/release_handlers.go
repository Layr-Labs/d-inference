package api

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"

	"github.com/dginf/coordinator/internal/auth"
	"github.com/dginf/coordinator/internal/store"
)

// handleRegisterRelease handles POST /v1/releases.
// Called by GitHub Actions to register a new provider binary release.
// Authenticated with a scoped release key (NOT admin credentials).
func (s *Server) handleRegisterRelease(w http.ResponseWriter, r *http.Request) {
	// Verify scoped release key.
	token := extractBearerToken(r)
	if s.releaseKey == "" || token != s.releaseKey {
		writeJSON(w, http.StatusUnauthorized, errorResponse("unauthorized", "invalid release key"))
		return
	}

	var release store.Release
	if err := json.NewDecoder(r.Body).Decode(&release); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if release.Version == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "version is required"))
		return
	}
	if release.Platform == "" {
		release.Platform = "macos-arm64" // default
	}
	if release.BinaryHash == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "binary_hash is required"))
		return
	}
	if release.URL == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "url is required"))
		return
	}

	if err := s.store.SetRelease(&release); err != nil {
		s.logger.Error("release: register failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to save release"))
		return
	}

	// Auto-update known binary hashes from all active releases.
	s.SyncBinaryHashes()

	s.logger.Info("release registered",
		"version", release.Version,
		"platform", release.Platform,
		"binary_hash", release.BinaryHash[:min(16, len(release.BinaryHash))]+"...",
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "release_registered",
		"release": release,
	})
}

// handleLatestRelease handles GET /v1/releases/latest.
// Public endpoint — returns the latest active release for a platform.
// Used by install.sh to get the download URL and expected hash.
func (s *Server) handleLatestRelease(w http.ResponseWriter, r *http.Request) {
	platform := r.URL.Query().Get("platform")
	if platform == "" {
		platform = "macos-arm64"
	}

	release := s.store.GetLatestRelease(platform)
	if release == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no active release for platform "+platform))
		return
	}

	writeJSON(w, http.StatusOK, release)
}

// handleAdminListReleases handles GET /v1/admin/releases.
// Admin-only — returns all releases (active and inactive).
func (s *Server) handleAdminListReleases(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	releases := s.store.ListReleases()
	if releases == nil {
		releases = []store.Release{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"releases": releases})
}

// handleAdminDeleteRelease handles DELETE /v1/admin/releases.
// Admin-only — deactivates a release version.
func (s *Server) handleAdminDeleteRelease(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}

	var req struct {
		Version  string `json:"version"`
		Platform string `json:"platform"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON: "+err.Error()))
		return
	}
	if req.Version == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "version is required"))
		return
	}
	if req.Platform == "" {
		req.Platform = "macos-arm64"
	}

	if err := s.store.DeleteRelease(req.Version, req.Platform); err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", err.Error()))
		return
	}

	// Re-sync known binary hashes after deactivation.
	s.SyncBinaryHashes()

	s.logger.Info("admin: release deactivated", "version", req.Version, "platform", req.Platform)
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "release_deactivated",
		"version":  req.Version,
		"platform": req.Platform,
	})
}

// isAdminAuthorized checks if the request is from an admin.
// Accepts either Privy admin (email in admin list) OR DGINF_ADMIN_KEY.
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON"))
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "invalid JSON"))
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
