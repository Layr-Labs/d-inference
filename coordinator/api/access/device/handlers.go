package device

// Device authorization endpoints (RFC 8628-style flow).
//
// This implements a device login flow for provider machines:
//   1. Provider CLI calls POST /v1/device/code → gets device_code + user_code
//   2. User opens verification_uri in browser, logs in via Privy, enters user_code
//   3. Provider CLI polls POST /v1/device/token with device_code → gets auth token
//   4. Provider uses auth token in WebSocket registration to link to account

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/internal/api/access/devicecode"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	// DeviceCodeExpiry is how long a device code is valid.
	DeviceCodeExpiry = 15 * time.Minute

	// DeviceCodePollInterval is the minimum interval between polls (seconds).
	DeviceCodePollInterval = 5
)

// HandleDeviceCode creates a new device authorization request.
// POST /v1/device/code
// No auth required — the provider CLI is not yet authenticated.
func (s *Handler) HandleDeviceCode(w http.ResponseWriter, r *http.Request) {
	// Generate device code (opaque, high-entropy secret).
	deviceCodeBytes := make([]byte, 32)
	if _, err := rand.Read(deviceCodeBytes); err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to generate device code"))
		return
	}
	deviceCode := hex.EncodeToString(deviceCodeBytes)

	// Generate user code (short, human-readable, uppercase alphanumeric).
	userCode, err := devicecode.Generate()
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to generate user code"))
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
		userCode, _ = devicecode.Generate()
		dc.UserCode = userCode
		if err := s.store.CreateDeviceCode(dc); err != nil {
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to create device code"))
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
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
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

// HandleDeviceToken polls for a device authorization result.
// POST /v1/device/token
// No auth required — security comes from the device_code being secret.
func (s *Handler) HandleDeviceToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceCode string `json:"device_code"`
	}
	if !httpx.DecodeCappedJSON(w, r, s.controlPlaneBodyBytes, &req) {
		return
	}
	if req.DeviceCode == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request", "device_code is required"))
		return
	}

	dc, err := s.store.GetDeviceCode(req.DeviceCode)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("invalid_grant", "device code not found"))
		return
	}

	// Check expiry.
	if time.Now().After(dc.ExpiresAt) {
		httpx.WriteJSON(w, http.StatusGone, httpx.ErrorResponse("expired_token", "device code has expired"))
		return
	}

	switch dc.Status {
	case "pending":
		httpx.
			// RFC 8628: "authorization_pending" — not yet approved.
			WriteJSON(w, http.StatusOK, map[string]any{
				"status": "authorization_pending",
			})

	case "approved":
		// Generate a long-lived provider token.
		tokenBytes := make([]byte, 32)
		if _, err := rand.Read(tokenBytes); err != nil {
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to generate token"))
			return
		}
		rawToken := "eigeninference-pt-" + hex.EncodeToString(tokenBytes)
		tokenHash := devicecode.Hash(rawToken)

		pt := &store.ProviderToken{
			TokenHash: tokenHash,
			AccountID: dc.AccountID,
			Label:     "device-" + dc.UserCode,
			Active:    true,
		}
		if err := s.store.CreateProviderToken(pt); err != nil {
			httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to create token"))
			return
		}

		s.logger.Info("provider token issued",
			"account_id", dc.AccountID,
			"user_code", dc.UserCode,
		)
		httpx.WriteJSON(w, http.StatusOK, map[string]any{
			"status":     "authorized",
			"token":      rawToken,
			"account_id": dc.AccountID,
		})

	default:
		httpx.WriteJSON(w, http.StatusGone, httpx.ErrorResponse("expired_token", "device code is no longer valid"))
	}
}

// HandleDeviceApprove approves a device code, linking it to the authenticated user's account.
// POST /v1/device/approve
// Requires Privy auth — the user must be logged in.
func (s *Handler) HandleDeviceApprove(w http.ResponseWriter, r *http.Request) {
	user := auth.UserFromContext(r.Context())
	if user == nil {
		httpx.WriteJSON(w, http.StatusUnauthorized, httpx.ErrorResponse("auth_error", "Privy authentication required"))
		return
	}

	var req struct {
		UserCode string `json:"user_code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.UserCode == "" {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request", "user_code is required"))
		return
	}

	// Normalize: uppercase, trim spaces.
	userCode := strings.ToUpper(strings.TrimSpace(req.UserCode))

	dc, err := s.store.GetDeviceCodeByUserCode(userCode)
	if err != nil {
		httpx.WriteJSON(w, http.StatusNotFound, httpx.ErrorResponse("invalid_code", "device code not found — check the code and try again"))
		return
	}

	if time.Now().After(dc.ExpiresAt) {
		httpx.WriteJSON(w, http.StatusGone, httpx.ErrorResponse("expired_code", "this code has expired — run 'darkbloom login' again"))
		return
	}

	if dc.Status != "pending" {
		httpx.WriteJSON(w, http.StatusConflict, httpx.ErrorResponse("already_used", "this code has already been used"))
		return
	}

	if err := s.store.ApproveDeviceCode(dc.DeviceCode, user.AccountID); err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("server_error", "failed to approve device"))
		return
	}

	s.logger.Info("device approved",
		"user_code", userCode,
		"account_id", user.AccountID,
	)
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"status":  "approved",
		"message": "Device linked successfully. Your provider will connect to your account shortly.",
	})
}
