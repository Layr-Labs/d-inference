package accounts

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httprequest"
	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// DeviceToken polls for a device authorization result.
// POST /v1/device/token
// No auth required — security comes from the device_code being secret.
func (s *Controller) DeviceToken(w http.ResponseWriter, r *http.Request) {
	var req struct {
		DeviceCode string `json:"device_code"`
	}
	if !httprequest.DecodeJSON(w, r, httprequest.ControlPlaneBodyLimit, &req) {
		return
	}
	if req.DeviceCode == "" {
		httpresponse.WriteJSON(w, http.StatusBadRequest, httpresponse.ErrorBody("invalid_request", "device_code is required"))
		return
	}

	dc, err := s.store().GetDeviceCode(req.DeviceCode)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("invalid_grant", "device code not found"))
		return
	}

	// Check expiry.
	if time.Now().After(dc.ExpiresAt) {
		httpresponse.WriteJSON(w, http.StatusGone, httpresponse.ErrorBody("expired_token", "device code has expired"))
		return
	}

	switch dc.Status {
	case "pending":
		// RFC 8628: "authorization_pending" — not yet approved.
		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
			"status": "authorization_pending",
		})

	case "approved":
		// Generate a long-lived provider token.
		tokenBytes := make([]byte, 32)
		if _, err := rand.Read(tokenBytes); err != nil {
			httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to generate token"))
			return
		}
		rawToken := "eigeninference-pt-" + hex.EncodeToString(tokenBytes)
		tokenHash := sha256Hash(rawToken)

		pt := &store.ProviderToken{
			TokenHash: tokenHash,
			AccountID: dc.AccountID,
			Label:     "device-" + dc.UserCode,
			Active:    true,
		}
		if err := s.store().CreateProviderToken(pt); err != nil {
			httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to create token"))
			return
		}

		s.logger.Info("provider token issued",
			"account_id", dc.AccountID,
			"user_code", dc.UserCode,
		)

		httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
			"status":     "authorized",
			"token":      rawToken,
			"account_id": dc.AccountID,
		})

	default:
		httpresponse.WriteJSON(w, http.StatusGone, httpresponse.ErrorBody("expired_token", "device code is no longer valid"))
	}
}

// sha256Hash returns the hex-encoded SHA-256 digest.
func sha256Hash(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
