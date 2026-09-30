package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/apns"
)

// testAPNsKeyPEM returns a fresh PKCS#8 PEM key of the kind Apple issues
// (.p8, ECDSA P-256). It is generated per test and is not a real credential.
func testAPNsKeyPEM(t *testing.T) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func clearAPNsEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"APNS_KEY_ID", "APNS_TEAM_ID", "APNS_AUTH_KEY_P8_B64",
		"APNS_AUTH_KEY_P8_PATH", "APNS_TOPIC", "APNS_MODE",
	} {
		t.Setenv(name, "")
	}
}

func TestLoadAPNsAttestorDisabledWithoutCompleteConfig(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	rsaKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	rsaDER, err := x509.MarshalPKCS8PrivateKey(rsaKey)
	if err != nil {
		t.Fatal(err)
	}
	rsaPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: rsaDER})

	cases := []struct {
		name string
		env  map[string]string
	}{
		{"nothing set", nil},
		{"key id without team id", map[string]string{"APNS_KEY_ID": "KEY123"}},
		{"ids without a key", map[string]string{"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123"}},
		{"key is not base64", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123", "APNS_AUTH_KEY_P8_B64": "%%%not-base64%%%",
		}},
		{"key file is missing", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123",
			"APNS_AUTH_KEY_P8_PATH": filepath.Join(t.TempDir(), "missing.p8"),
		}},
		{"key is not PEM", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123",
			"APNS_AUTH_KEY_P8_B64": base64.StdEncoding.EncodeToString([]byte("not a pem block")),
		}},
		{"key is RSA, not P-256", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123",
			"APNS_AUTH_KEY_P8_B64": base64.StdEncoding.EncodeToString(rsaPEM),
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			clearAPNsEnv(t)
			for k, v := range tc.env {
				t.Setenv(k, v)
			}
			if got := loadAPNsAttestor(logger); got != nil {
				t.Fatalf("attestor enabled with incomplete or invalid config %v", tc.env)
			}
		})
	}
}

func TestLoadAPNsAttestorFromBase64Key(t *testing.T) {
	clearAPNsEnv(t)
	t.Setenv("APNS_KEY_ID", "KEY123")
	t.Setenv("APNS_TEAM_ID", "TEAM123")
	t.Setenv("APNS_AUTH_KEY_P8_B64", base64.StdEncoding.EncodeToString(testAPNsKeyPEM(t)))

	attestor := loadAPNsAttestor(slog.New(slog.NewTextHandler(io.Discard, nil)))
	if attestor == nil {
		t.Fatal("valid base64 key did not enable the attestor")
	}
	if attestor.Mode() != apns.ModeBackground {
		t.Fatalf("default mode = %q, want %q", attestor.Mode(), apns.ModeBackground)
	}
}

func TestLoadAPNsAttestorFromKeyFileInAlertMode(t *testing.T) {
	clearAPNsEnv(t)
	path := filepath.Join(t.TempDir(), "auth.p8")
	if err := os.WriteFile(path, testAPNsKeyPEM(t), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("APNS_KEY_ID", "KEY123")
	t.Setenv("APNS_TEAM_ID", "TEAM123")
	t.Setenv("APNS_AUTH_KEY_P8_PATH", path)
	t.Setenv("APNS_TOPIC", "example.test.provider")
	t.Setenv("APNS_MODE", "alert")

	attestor := loadAPNsAttestor(slog.New(slog.NewTextHandler(io.Discard, nil)))
	if attestor == nil {
		t.Fatal("valid key file did not enable the attestor")
	}
	if attestor.Mode() != apns.ModeAlert {
		t.Fatalf("mode = %q, want %q", attestor.Mode(), apns.ModeAlert)
	}
}
