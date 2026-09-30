package main

import (
	"encoding/base64"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// startupEnv is the environment for an in-process run of main with the
// in-memory store. Every value is local test data. Optional settings are
// turned on so their startup wiring runs; only settings that change one
// server or registry instance are used, never process-wide tuning globals.
func startupEnv(t *testing.T, port string) map[string]string {
	return map[string]string{
		"EIGENINFERENCE_DATABASE_URL":                 "",
		"EIGENINFERENCE_ALLOW_MEMORY_STORE":           "true",
		"EIGENINFERENCE_PORT":                         port,
		"EIGENINFERENCE_ADMIN_KEY":                    "startup-test-admin-key",
		"EIGENINFERENCE_ADMIN_EMAILS":                 "admin@example.test",
		"EIGENINFERENCE_DRAIN_GRACE":                  "1s",
		"EIGENINFERENCE_DEDICATED_MODELS":             "none",
		"EIGENINFERENCE_RELEASE_POLICY_MODE":          "enforce",
		"EIGENINFERENCE_RELEASE_POLICY_ENFORCE_GRACE": "5m",
		"EIGENINFERENCE_BINARYHASH_ENFORCE":           "true",
		"EIGENINFERENCE_TTFT_HARD_REJECT":             "true",
		"EIGENINFERENCE_REJECT_MODELS":                "shed-model-a, ,shed-model-b",
		"EIGENINFERENCE_LONG_PROMPT_TOKENS":           "not-a-number",
		"EIGENINFERENCE_MIN_DECODE_TPS":               "20",
		"EIGENINFERENCE_ROUTING_CONCURRENCY":          "1",
		"EIGENINFERENCE_SERVABILITY_GATE":             "false",
		"EIGENINFERENCE_DISABLE_CLIENT_ERROR_STOP":    "true",
		"EIGENINFERENCE_KNOWN_TEMPLATE_HASHES":        "model-a=hash-a,malformed",
		"EIGENINFERENCE_KNOWN_BINARY_HASHES":          "binary-hash-a,binary-hash-b",
		"EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS":   "1",
		"EIGENINFERENCE_MDM_URL":                      "",
		"EIGENINFERENCE_PPROF_ADDR":                   "",
		"EIGENINFERENCE_PROMPT_SIDECAR_ENABLED":       "false",
		"DD_API_KEY":                                  "",
		"DD_AGENT_HOST":                               "",
		"PRIVY_APP_ID":                                "",
		"APNS_KEY_ID":                                 "KEY123",
		"APNS_TEAM_ID":                                "TEAM123",
		"APNS_AUTH_KEY_P8_B64":                        base64.StdEncoding.EncodeToString(testAPNsKeyPEM(t)),
		"APNS_AUTH_KEY_P8_PATH":                       "",
		"APNS_ENFORCE_AFTER":                          time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339),
	}
}

func freeLocalPort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	if err := ln.Close(); err != nil {
		t.Fatal(err)
	}
	return port
}

// TestMainServesWithMemoryStoreAndDrainsOnSIGTERM runs the real main function
// in this process: configuration, store selection, server wiring, listening,
// and the SIGTERM drain and shutdown path.
func TestMainServesWithMemoryStoreAndDrainsOnSIGTERM(t *testing.T) {
	port := freeLocalPort(t)
	for k, v := range startupEnv(t, port) {
		t.Setenv(k, v)
	}
	savedArgs := os.Args
	os.Args = []string{"coordinator"}
	t.Cleanup(func() { os.Args = savedArgs })

	// main logs JSON to os.Stdout. Capture it so the test can read the
	// startup and shutdown lines, then restore stdout and the default logger.
	logPath := filepath.Join(t.TempDir(), "coordinator.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		t.Fatal(err)
	}
	savedStdout, savedLogger := os.Stdout, slog.Default()
	os.Stdout = logFile
	t.Cleanup(func() {
		os.Stdout = savedStdout
		slog.SetDefault(savedLogger)
		_ = logFile.Close()
	})

	// Keep SIGTERM from killing the test binary before main registers its
	// own handler; a registered channel turns off the default action.
	guard := make(chan os.Signal, 16)
	signal.Notify(guard, syscall.SIGTERM)
	t.Cleanup(func() { signal.Stop(guard) })

	done := make(chan struct{})
	go func() {
		defer close(done)
		main()
	}()

	base := "http://127.0.0.1:" + port
	client := &http.Client{Timeout: 2 * time.Second}
	deadline := time.Now().Add(30 * time.Second)
	for {
		resp, err := client.Get(base + "/health")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				break
			}
		}
		select {
		case <-done:
			t.Fatalf("main returned before serving; log:\n%s", readFile(t, logPath))
		default:
		}
		if time.Now().After(deadline) {
			t.Fatalf("coordinator did not become healthy; last error %v", err)
		}
		time.Sleep(50 * time.Millisecond)
	}

	if code := getStatus(t, client, base+"/v1/models", ""); code != http.StatusUnauthorized {
		t.Fatalf("/v1/models without a key = %d, want 401", code)
	}
	if code := getStatus(t, client, base+"/v1/models", "startup-test-admin-key"); code != http.StatusOK {
		t.Fatalf("/v1/models with the seeded admin key = %d, want 200", code)
	}

	// Send SIGTERM until main returns. The first signal can arrive before
	// main has called signal.Notify; later ones reach its channel.
	stop := time.After(60 * time.Second)
	tick := time.NewTicker(100 * time.Millisecond)
	defer tick.Stop()
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
wait:
	for {
		select {
		case <-done:
			break wait
		case <-tick.C:
			_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
		case <-stop:
			t.Fatal("main did not return after SIGTERM")
		}
	}

	if _, err := client.Get(base + "/health"); err == nil {
		t.Fatal("server still accepts requests after shutdown")
	}
	logs := readFile(t, logPath)
	for _, want := range []string{
		"using in-memory store",
		"release-policy routing gate ENFORCED",
		"model shed ENABLED",
		"invalid EIGENINFERENCE_LONG_PROMPT_TOKENS",
		"invalid EIGENINFERENCE_ROUTING_CONCURRENCY",
		"smart servability gate DISABLED",
		"runtime manifest configured from env",
		"additional binary hashes from env var",
		"APNs code-identity attestation configured — GRACE until the enforcement deadline",
		"coordinator starting",
		"shutting down",
		"coordinator stopped",
	} {
		if !strings.Contains(logs, want) {
			t.Errorf("startup log is missing %q", want)
		}
	}
}

func getStatus(t *testing.T, client *http.Client, url, bearer string) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
