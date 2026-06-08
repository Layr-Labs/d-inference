package apns

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
)

// TestLiveRoundTripAPNs is an ON-DEVICE live test (skipped unless APNS_LIVE_TEST=1).
// It uses the REAL apns package to push E_K(nonce) over REAL APNs to a device token
// produced by an on-device probe, then confirms the delivered code_challenge
// decrypts to the exact nonce — i.e. the production sender delivers a correct,
// decryptable encrypted challenge to the real bundle over Apple's infrastructure.
//
// Requires env: APNS_AUTH_KEY_P8_B64, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC
// (+ optional APNS_MODE=background|alert), and the probe running (writing
// /tmp/apns_coexist_token.txt and, on receipt, /tmp/lt_received.json).
func TestLiveRoundTripAPNs(t *testing.T) {
	if os.Getenv("APNS_LIVE_TEST") != "1" {
		t.Skip("set APNS_LIVE_TEST=1 (+ APNS_* env and a running probe) to run the on-device APNs live test")
	}
	pemB64 := os.Getenv("APNS_AUTH_KEY_P8_B64")
	if pemB64 == "" {
		t.Fatal("APNS_AUTH_KEY_P8_B64 not set")
	}
	pem, err := base64.StdEncoding.DecodeString(pemB64)
	if err != nil {
		t.Fatalf("decode APNS_AUTH_KEY_P8_B64: %v", err)
	}
	tokenRaw, err := os.ReadFile("/tmp/apns_coexist_token.txt")
	if err != nil {
		t.Fatalf("read device token (is the probe running?): %v", err)
	}
	token := strings.TrimSpace(string(tokenRaw))

	mode := ModeBackground
	if os.Getenv("APNS_MODE") == "alert" {
		mode = ModeAlert
	}
	attestor, err := NewAPNsPushAttestor(Config{
		TeamID:     os.Getenv("APNS_TEAM_ID"),
		KeyID:      os.Getenv("APNS_KEY_ID"),
		Topic:      getenvOr("APNS_TOPIC", "io.darkbloom.provider"),
		AuthKeyPEM: pem,
		Mode:       mode,
	})
	if err != nil {
		t.Fatalf("NewAPNsPushAttestor: %v", err)
	}

	// We hold the provider's K private key so we can verify the delivered challenge.
	k, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("gen K: %v", err)
	}
	kPub := base64.StdEncoding.EncodeToString(k.PublicKey[:])
	nonceB64 := base64.StdEncoding.EncodeToString([]byte("live-roundtrip-nonce-0123456789ab"))

	_ = os.Remove("/tmp/lt_received.json")
	if err := attestor.SendCodeChallenge(context.Background(), token, "production", kPub, nonceB64); err != nil {
		t.Fatalf("SendCodeChallenge (mode=%s): %v", mode, err)
	}
	t.Logf("pushed E_K(nonce) via real APNs (mode=%s) to device %s…", mode, token[:min(12, len(token))])

	var recv []byte
	for i := 0; i < 90; i++ {
		if b, e := os.ReadFile("/tmp/lt_received.json"); e == nil && len(b) > 0 {
			recv = b
			break
		}
		time.Sleep(time.Second)
	}
	if recv == nil {
		t.Fatalf("on-device probe did NOT receive the push within 90s (mode=%s) — APNs delivery (budget/subscription) issue, not a code bug", mode)
	}

	var payload e2e.EncryptedPayload
	if err := json.Unmarshal(recv, &payload); err != nil {
		t.Fatalf("received code_challenge is not an EncryptedPayload: %v", err)
	}
	recovered, err := e2e.Decrypt(&payload, k)
	if err != nil {
		t.Fatalf("decrypt of the delivered challenge failed: %v", err)
	}
	if string(recovered) != nonceB64 {
		t.Fatalf("recovered nonce mismatch: got %q want %q", recovered, nonceB64)
	}
	t.Logf("✅ LIVE PASS: real apns package delivered E_K(nonce) over real APNs to %s; on-device receipt decrypts to the exact nonce", attestor.topic)
}

func getenvOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
