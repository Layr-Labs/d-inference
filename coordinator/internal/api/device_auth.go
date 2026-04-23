package api

// Device authorization endpoints (RFC 8628-style flow).
//
// This implements a device login flow for provider machines:
//   1. Provider CLI calls POST /v1/device/code → gets device_code + user_code
//   2. User opens verification_uri in browser, logs in via Privy, enters user_code
//   3. Provider CLI polls POST /v1/device/token with device_code → gets auth token
//   4. Provider uses auth token in WebSocket registration to link to account

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/coordinator/internal/auth"
	"github.com/eigeninference/coordinator/internal/store"
)

const (
	// DeviceCodeExpiry is how long a device code is valid.
	DeviceCodeExpiry = 15 * time.Minute

	// DeviceCodePollInterval is the minimum interval between polls (seconds).
	DeviceCodePollInterval = 5
)

// handleDeviceCode creates a new device authorization request.
// POST /v1/device/code
// No auth required — the provider CLI is not yet authenticated.
func (s *Server) handleDeviceCode(w http.ResponseWriter, r *http.Request) {
	// Generate device code (opaque, high-entropy secret).
	deviceCodeBytes := make([]byte, 32)
	if _, err := rand.Read(deviceCodeBytes); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to generate device code"))
		return
	}
	deviceCode := hex.EncodeToString(deviceCodeBytes)

	// Generate user code (short, human-readable, uppercase alphanumeric).
	userCode, err := generateUserCode()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to generate user code"))
		return
	}

	dc := &store.DeviceCode{
		DeviceCode: deviceCode,
		UserCode:   userCode,
		Status:     "pending",
		ExpiresAt:  time.Now().Add(DeviceCodeExpiry),
	}

	if err := s.store.CreateDeviceCode(dc); err != nil {
		// User code collision — retry once.
		userCode, _ = generateUserCode()
		dc.UserCode = userCode
		if err := s.store.CreateDeviceCode(dc); err != nil {
			writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create device code"))
			return
		}
	}

	// Build verification URI. If a console URL is configured (separate frontend),
	// use that. Otherwise fall back to the coordinator's own host.
	var verificationURI string
	if s.consoleURL != "" {
		verificationURI = strings.TrimRight(s.consoleURL, "/") + "/link"
	} else {
		scheme := "https"
		if r.TLS == nil && !strings.Contains(r.Host, "darkbloom.dev") {
			scheme = "http"
		}
		verificationURI = fmt.Sprintf("%s://%s/link", scheme, r.Host)
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"device_code":      deviceCode,
		"user_code":        userCode,
		"verification_uri": verificationURI,
		"expires_in":       int(DeviceCodeExpiry.Seconds()),
		"interval":         DeviceCodePollInterval,
	})

	s.logger.Info("device code created",
		"user_code", userCode,
		"expires_in", DeviceCodeExpiry.String(),
	)
}

// handleDeviceToken polls for a device authorization result.
// POST /v1/device/token
// No auth required — security comes from the device_code being secret.
func (s *Server) handleDeviceToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceCode string `json:"device_code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.DeviceCode == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", "device_code is required"))
		return
	}

	dc, err := s.store.GetDeviceCode(req.DeviceCode)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("invalid_grant", "device code not found"))
		return
	}

	// Check expiry.
	if time.Now().After(dc.ExpiresAt) {
		writeJSON(w, http.StatusGone, errorResponse("expired_token", "device code has expired"))
		return
	}

	switch dc.Status {
	case "pending":
		// RFC 8628: "authorization_pending" — not yet approved.
		writeJSON(w, http.StatusOK, map[string]any{
			"status": "authorization_pending",
		})

	case "approved":
		// Generate a long-lived provider token.
		tokenBytes := make([]byte, 32)
		if _, err := rand.Read(tokenBytes); err != nil {
			writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to generate token"))
			return
		}
		rawToken := "eigeninference-pt-" + hex.EncodeToString(tokenBytes)
		tokenHash := sha256Hash(rawToken)

		pt := &store.ProviderToken{
			TokenHash: tokenHash,
			AccountID: dc.AccountID,
			Label:     fmt.Sprintf("device-%s", dc.UserCode),
			Active:    true,
		}
		if err := s.store.CreateProviderToken(pt); err != nil {
			writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to create token"))
			return
		}

		s.logger.Info("provider token issued",
			"account_id", dc.AccountID,
			"user_code", dc.UserCode,
		)

		writeJSON(w, http.StatusOK, map[string]any{
			"status":     "authorized",
			"token":      rawToken,
			"account_id": dc.AccountID,
		})

	default:
		writeJSON(w, http.StatusGone, errorResponse("expired_token", "device code is no longer valid"))
	}
}

// handleDeviceApprove approves a device code, linking it to the authenticated user's account.
// POST /v1/device/approve
// Requires Privy auth — the user must be logged in.
func (s *Server) handleDeviceApprove(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		writeJSON(w, http.StatusUnauthorized, errorResponse("auth_error", "Privy authentication required"))
		return
	}

	var req struct {
		UserCode string `json:"user_code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserCode == "" {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", "user_code is required"))
		return
	}

	// Normalize: uppercase, trim spaces.
	userCode := strings.ToUpper(strings.TrimSpace(req.UserCode))

	dc, err := s.store.GetDeviceCodeByUserCode(userCode)
	if err != nil {
		writeJSON(w, http.StatusNotFound, errorResponse("invalid_code", "device code not found — check the code and try again"))
		return
	}

	if time.Now().After(dc.ExpiresAt) {
		writeJSON(w, http.StatusGone, errorResponse("expired_code", "this code has expired — run 'darkbloom login' again"))
		return
	}

	if dc.Status != "pending" {
		writeJSON(w, http.StatusConflict, errorResponse("already_used", "this code has already been used"))
		return
	}

	if err := s.store.ApproveDeviceCode(dc.DeviceCode, user.AccountID); err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("server_error", "failed to approve device"))
		return
	}

	s.logger.Info("device approved",
		"user_code", userCode,
		"account_id", user.AccountID,
		"email", user.Email,
	)

	writeJSON(w, http.StatusOK, map[string]any{
		"status":  "approved",
		"message": "Device linked successfully. Your provider will connect to your account shortly.",
	})
}

// generateUserCode creates a short, human-readable code like "ABCD-1234".
func generateUserCode() (string, error) {
	// Use alphanumeric chars (no ambiguous chars: 0/O, 1/I/L).
	const charset = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

	code := make([]byte, 8)
	for i := range code {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			return "", err
		}
		code[i] = charset[n.Int64()]
	}

	// Format as XXXX-XXXX for readability.
	return string(code[:4]) + "-" + string(code[4:]), nil
}

// sha256Hash returns the hex-encoded SHA-256 digest.
func sha256Hash(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
