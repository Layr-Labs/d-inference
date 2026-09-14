package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Run the real entrypoint with an isolated environment and a local listener.
// The process boundary observes startup refusal, public routes and SIGTERM;
// it does not stub the composition functions being refactored.
func TestCoordinatorStartupAndDrainProcess(t *testing.T) {
	for _, scenario := range []string{"serve and drain", "missing durable store", "invalid enforcement deadline"} {
		t.Run(scenario, func(t *testing.T) {
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			_, port, err := net.SplitHostPort(listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			listener.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestCoordinatorStartupHelperProcess$")
			cmd.Env = []string{
				"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(),
				"COORDINATOR_STARTUP_TEST_HELPER=1",
				"EIGENINFERENCE_PORT=" + port,
				"EIGENINFERENCE_ADMIN_KEY=startup-fixture-admin",
				"EIGENINFERENCE_PROMPT_SIDECAR_ENABLED=false",
				"EIGENINFERENCE_DRAIN_GRACE=1s",
			}
			if scenario != "missing durable store" {
				cmd.Env = append(cmd.Env, "EIGENINFERENCE_ALLOW_MEMORY_STORE=true")
			}
			if scenario == "invalid enforcement deadline" {
				key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
				if err != nil {
					t.Fatal(err)
				}
				der, err := x509.MarshalPKCS8PrivateKey(key)
				if err != nil {
					t.Fatal(err)
				}
				keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
				cmd.Env = append(cmd.Env, "APNS_KEY_ID=fixture-key", "APNS_TEAM_ID=fixture-team",
					"APNS_AUTH_KEY_P8_B64="+base64.StdEncoding.EncodeToString(keyPEM), "APNS_ENFORCE_AFTER=invalid")
			}
			logPath := filepath.Join(t.TempDir(), "coordinator.log")
			logs, err := os.Create(logPath)
			if err != nil {
				t.Fatal(err)
			}
			defer logs.Close()
			cmd.Stdout, cmd.Stderr = logs, logs
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- cmd.Wait() }()
			waited := false
			defer func() {
				cancel()
				if !waited {
					<-done
				}
			}()
			readLogs := func() string {
				b, err := os.ReadFile(logPath)
				if err != nil {
					t.Fatal(err)
				}
				return string(b)
			}
			if scenario != "serve and drain" {
				err := <-done
				waited = true
				var want string
				if scenario == "missing durable store" {
					want = "invalid configuration"
				} else {
					want = "refusing to start: APNS_ENFORCE_AFTER is set but invalid"
				}
				output := readLogs()
				if err == nil || ctx.Err() != nil || !strings.Contains(output, want) || strings.Contains(output, "coordinator starting") {
					t.Fatalf("startup did not fail before serving: err=%v ctx=%v\n%s", err, ctx.Err(), output)
				}
				return
			}

			client := &http.Client{Timeout: time.Second}
			base := "http://127.0.0.1:" + port
			ticker := time.NewTicker(10 * time.Millisecond)
			defer ticker.Stop()
			for {
				resp, err := client.Get(base + "/readyz")
				if err == nil {
					resp.Body.Close()
					if resp.StatusCode == http.StatusOK {
						break
					}
				}
				select {
				case err := <-done:
					waited = true
					t.Fatalf("exited before ready: %v\n%s", err, readLogs())
				case <-ctx.Done():
					t.Fatalf("never ready: %v\n%s", ctx.Err(), readLogs())
				case <-ticker.C:
				}
			}
			request := func(method, path, body string, want int) []byte {
				t.Helper()
				r, err := http.NewRequestWithContext(ctx, method, base+path, strings.NewReader(body))
				if err != nil {
					t.Fatal(err)
				}
				if path == "/v1/admin/drain" {
					r.Header.Set("Authorization", "Bearer startup-fixture-admin")
				}
				resp, err := client.Do(r)
				if err != nil {
					t.Fatal(err)
				}
				defer resp.Body.Close()
				b, err := io.ReadAll(resp.Body)
				if err != nil || resp.StatusCode != want {
					t.Fatalf("%s %s: status=%d want=%d err=%v body=%s", method, path, resp.StatusCode, want, err, b)
				}
				return b
			}
			request(http.MethodPost, "/v1/admin/drain", "", http.StatusOK)
			ready := request(http.MethodGet, "/readyz", "", http.StatusServiceUnavailable)
			var state struct {
				Draining bool  `json:"draining"`
				Ready    bool  `json:"ready"`
				Inflight int64 `json:"inflight"`
			}
			if err := json.Unmarshal(ready, &state); err != nil || !state.Draining || state.Ready || state.Inflight != 0 {
				t.Fatalf("unexpected drained state: %s err=%v", ready, err)
			}
			request(http.MethodGet, "/health", "", http.StatusOK)
			request(http.MethodPost, "/v1/chat/completions", `{}`, http.StatusTooManyRequests)
			request(http.MethodPost, "/v1/admin/drain", `{"draining":false}`, http.StatusOK)
			request(http.MethodGet, "/readyz", "", http.StatusOK)
			if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
				t.Fatal(err)
			}
			err = <-done
			waited = true
			output := readLogs()
			finished, stopped := strings.Index(output, "drain complete; in-flight requests finished"), strings.Index(output, "coordinator stopped")
			if err != nil || ctx.Err() != nil || finished < 0 || stopped <= finished || bytes.Contains([]byte(output), []byte("DATA RACE")) {
				t.Fatalf("shutdown did not drain then stop cleanly: err=%v ctx=%v\n%s", err, ctx.Err(), output)
			}
		})
	}
}

func TestCoordinatorStartupHelperProcess(t *testing.T) {
	if os.Getenv("COORDINATOR_STARTUP_TEST_HELPER") != "1" {
		return
	}
	os.Args = []string{"coordinator"}
	main()
}
