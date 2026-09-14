package accounts

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// DeviceCodeExpiry is how long a device code is valid.
const DeviceCodeExpiry = 15 * time.Minute

// DeviceCodePollInterval is the minimum interval between polls in seconds.
const DeviceCodePollInterval = 5

// DeviceCode creates a new device authorization request.
// POST /v1/device/code
// No auth required — the provider CLI is not yet authenticated.
func (s *Controller) DeviceCode(w http.ResponseWriter, r *http.Request) {
	// Generate device code (opaque, high-entropy secret).
	deviceCodeBytes := make([]byte, 32)
	if _, err := rand.Read(deviceCodeBytes); err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to generate device code"))
		return
	}
	deviceCode := hex.EncodeToString(deviceCodeBytes)

	// Generate user code (short, human-readable, uppercase alphanumeric).
	userCode, err := generateUserCode()
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to generate user code"))
		return
	}

	dc := &store.DeviceCode{
		DeviceCode: deviceCode,
		UserCode:   userCode,
		Status:     "pending",
		ExpiresAt:  time.Now().Add(DeviceCodeExpiry),
	}

	if err := s.store().CreateDeviceCode(dc); err != nil {
		// User code collision — retry once.
		userCode, _ = generateUserCode()
		dc.UserCode = userCode
		if err := s.store().CreateDeviceCode(dc); err != nil {
			httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("server_error", "failed to create device code"))
			return
		}
	}

	// Build verification URI. If a console URL is configured (separate frontend),
	// use that. Otherwise fall back to the coordinator's own host.
	var verificationURI string
	if s.consoleURL() != "" {
		verificationURI = strings.TrimRight(s.consoleURL(), "/") + "/link"
	} else {
		scheme := "https"
		if r.TLS == nil && !strings.Contains(r.Host, "darkbloom.dev") {
			scheme = "http"
		}
		verificationURI = fmt.Sprintf("%s://%s/link", scheme, r.Host)
	}

	httpresponse.WriteJSON(w, http.StatusOK, map[string]any{
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
