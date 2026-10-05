package app_test

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/app"
	"github.com/eigeninference/d-inference/coordinator/config"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
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

// startupLog collects the coordinator's log output across its goroutines.
type startupLog struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (l *startupLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.Write(p)
}

func (l *startupLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.buf.String()
}

// runCoordinator starts app.Run with the in-memory store and the given APNs
// environment, stops it with SIGTERM and returns its log.
func runCoordinator(t *testing.T, apnsEnv map[string]string) string {
	t.Helper()
	port := testkit.FreeListenPort(t)
	for k, v := range map[string]string{
		"EIGENINFERENCE_DATABASE_URL":           "",
		"EIGENINFERENCE_ALLOW_MEMORY_STORE":     "true",
		"EIGENINFERENCE_PORT":                   port,
		"EIGENINFERENCE_DRAIN_GRACE":            "1s",
		"EIGENINFERENCE_MDM_URL":                "",
		"EIGENINFERENCE_PPROF_ADDR":             "",
		"EIGENINFERENCE_PROMPT_SIDECAR_ENABLED": "false",
		"DD_API_KEY":                            "",
		"PRIVY_APP_ID":                          "",
		"APNS_KEY_ID":                           "",
		"APNS_TEAM_ID":                          "",
		"APNS_AUTH_KEY_P8_B64":                  "",
		"APNS_AUTH_KEY_P8_PATH":                 "",
		"APNS_TOPIC":                            "",
		"APNS_MODE":                             "",
		"APNS_ENFORCE_AFTER":                    "",
	} {
		t.Setenv(k, v)
	}
	for k, v := range apnsEnv {
		t.Setenv(k, v)
	}
	cfg := config.ReadAppConfig()
	if err := cfg.Check(); err != nil {
		t.Fatalf("config: %v", err)
	}

	// Keep SIGTERM from killing the test binary before Run registers its
	// own handler; a registered channel turns off the default action.
	guard := make(chan os.Signal, 16)
	signal.Notify(guard, syscall.SIGTERM)
	defer signal.Stop(guard)

	var logs startupLog
	done := make(chan struct{})
	go func() {
		defer close(done)
		app.Run(cfg, slog.New(slog.NewTextHandler(&logs, nil)))
	}()
	// Run reads the signal only after startup, so repeat SIGTERM until it returns.
	stop := time.After(60 * time.Second)
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-done:
			out := logs.String()
			if !strings.Contains(out, "coordinator stopped") {
				t.Fatalf("Run returned without a clean shutdown; log:\n%s", out)
			}
			return out
		case <-tick.C:
			_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
		case <-stop:
			t.Fatal("Run did not return after SIGTERM")
		}
	}
}

const apnsDisabled = "APNs code-identity attestation not configured"

func TestAPNsAttestorDisabledWithoutCompleteConfig(t *testing.T) {
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
		name   string
		env    map[string]string
		reason string
	}{
		{"nothing set", nil, apnsDisabled},
		{"key id without team id", map[string]string{"APNS_KEY_ID": "KEY123"}, apnsDisabled},
		{"ids without a key", map[string]string{"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123"},
			"APNS_KEY_ID/APNS_TEAM_ID set but no .p8"},
		{"key is not base64", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123", "APNS_AUTH_KEY_P8_B64": "%%%not-base64%%%",
		}, "APNS_AUTH_KEY_P8_B64 is not valid base64"},
		{"key file is missing", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123",
			"APNS_AUTH_KEY_P8_PATH": filepath.Join(t.TempDir(), "missing.p8"),
		}, "failed to read APNS_AUTH_KEY_P8_PATH"},
		{"key is not PEM", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123",
			"APNS_AUTH_KEY_P8_B64": base64.StdEncoding.EncodeToString([]byte("not a pem block")),
		}, "failed to construct APNs attestor"},
		{"key is RSA, not P-256", map[string]string{
			"APNS_KEY_ID": "KEY123", "APNS_TEAM_ID": "TEAM123",
			"APNS_AUTH_KEY_P8_B64": base64.StdEncoding.EncodeToString(rsaPEM),
		}, "failed to construct APNs attestor"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			logs := runCoordinator(t, tc.env)
			if !strings.Contains(logs, tc.reason) || !strings.Contains(logs, apnsDisabled) {
				t.Fatalf("log does not show the attestor disabled by %q:\n%s", tc.reason, logs)
			}
		})
	}
}

func TestAPNsAttestorFromBase64KeyIsInGraceUntilTheDeadline(t *testing.T) {
	logs := runCoordinator(t, map[string]string{
		"APNS_KEY_ID":          "KEY123",
		"APNS_TEAM_ID":         "TEAM123",
		"APNS_AUTH_KEY_P8_B64": base64.StdEncoding.EncodeToString(testAPNsKeyPEM(t)),
		"APNS_ENFORCE_AFTER":   time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339),
	})
	if !strings.Contains(logs, "APNs code-identity attestation configured — GRACE until the enforcement deadline") {
		t.Fatalf("valid base64 key did not enable the attestor:\n%s", logs)
	}
}

func TestAPNsAttestorFromKeyFileIsInGraceWithoutADeadline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "auth.p8")
	if err := os.WriteFile(path, testAPNsKeyPEM(t), 0o600); err != nil {
		t.Fatal(err)
	}
	logs := runCoordinator(t, map[string]string{
		"APNS_KEY_ID":           "KEY123",
		"APNS_TEAM_ID":          "TEAM123",
		"APNS_AUTH_KEY_P8_PATH": path,
		"APNS_TOPIC":            "example.test.provider",
		"APNS_MODE":             "alert",
	})
	if !strings.Contains(logs, "APNs code-identity attestation configured in GRACE mode") {
		t.Fatalf("valid key file did not enable the attestor:\n%s", logs)
	}
}
