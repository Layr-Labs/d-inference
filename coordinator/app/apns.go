package app

import (
	"encoding/base64"
	"log/slog"
	"os"

	"github.com/eigeninference/d-inference/coordinator/apns"
)

// loadAPNsAttestor builds the production APNs code-identity attestor from the
// environment, or returns nil (feature disabled) when unconfigured. Required:
// APNS_KEY_ID, APNS_TEAM_ID, and the .p8 auth key via APNS_AUTH_KEY_P8_B64
// (base64 of the PEM) or APNS_AUTH_KEY_P8_PATH. Optional: APNS_TOPIC
// (default io.darkbloom.provider), APNS_MODE ("background" default | "alert").
// The .p8 is a secret — inject via KMS, never commit it.
func loadAPNsAttestor(logger *slog.Logger) *apns.APNsPushAttestor {
	keyID := os.Getenv("APNS_KEY_ID")
	teamID := os.Getenv("APNS_TEAM_ID")
	if keyID == "" || teamID == "" {
		return nil
	}

	var pemBytes []byte
	if b64 := os.Getenv("APNS_AUTH_KEY_P8_B64"); b64 != "" {
		dec, err := base64.StdEncoding.DecodeString(b64)
		if err != nil {
			logger.Error("APNS_AUTH_KEY_P8_B64 is not valid base64 — APNs attestation disabled", "error", err)
			return nil
		}
		pemBytes = dec
	} else if path := os.Getenv("APNS_AUTH_KEY_P8_PATH"); path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			logger.Error("failed to read APNS_AUTH_KEY_P8_PATH — APNs attestation disabled", "path", path, "error", err)
			return nil
		}
		pemBytes = b
	} else {
		logger.Warn("APNS_KEY_ID/APNS_TEAM_ID set but no .p8 (APNS_AUTH_KEY_P8_B64 or _PATH) — APNs attestation disabled")
		return nil
	}

	topic := os.Getenv("APNS_TOPIC")
	if topic == "" {
		topic = "io.darkbloom.provider"
	}
	mode := apns.ModeBackground
	if os.Getenv("APNS_MODE") == "alert" {
		mode = apns.ModeAlert
	}

	attestor, err := apns.NewAPNsPushAttestor(apns.Config{
		TeamID:     teamID,
		KeyID:      keyID,
		Topic:      topic,
		AuthKeyPEM: pemBytes,
		Mode:       mode,
	})
	if err != nil {
		logger.Error("failed to construct APNs attestor — attestation disabled", "error", err)
		return nil
	}
	return attestor
}
