package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestClientConfigRequiresHTTPSAndDoesNotExposeCredentials(t *testing.T) {
	for _, origin := range []string{"http://example.com", "https://user:secret@example.com", "https://example.com/v1", "https://example.com?key=secret", "file:///tmp/socket"} {
		var output bytes.Buffer
		_, _, err := parseConfig([]string{"--api-url", origin, "--allow-insecure-localhost", "list"}, func(name string) string {
			if name == "DARKBLOOM_API_KEY" {
				return fixtureAPIKey
			}
			return ""
		}, &output)
		if err == nil {
			t.Fatalf("unsafe origin accepted: %s", origin)
		}
		if strings.Contains(err.Error()+output.String(), "secret") || strings.Contains(err.Error()+output.String(), fixtureAPIKey) {
			t.Fatal("configuration error exposed credentials")
		}
	}
	var stdout, stderr bytes.Buffer
	code := runCLI(context.Background(), []string{"--help"}, func(name string) string {
		if name == "DARKBLOOM_API_URL" {
			return "https://user:environment-secret@example.com"
		}
		return ""
	}, &stdout, &stderr)
	if code != 0 || strings.Contains(stdout.String()+stderr.String(), "environment-secret") {
		t.Fatal("help exposed environment URL credentials")
	}
}

func TestClientDoesNotFollowCredentialedRedirects(t *testing.T) {
	var destinationCalls atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { destinationCalls.Add(1); w.WriteHeader(200) }))
	defer destination.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, destination.URL, http.StatusTemporaryRedirect)
	}))
	defer source.Close()
	client := newSandboxClient(clientConfig{baseURL: source.URL, apiKey: fixtureAPIKey})
	if err := client.jsonRequest(context.Background(), http.MethodGet, "/v1/sandboxes", "", nil, &map[string]any{}); err == nil {
		t.Fatal("redirect unexpectedly succeeded")
	}
	if destinationCalls.Load() != 0 {
		t.Fatal("client forwarded a credentialed request through a redirect")
	}
}

func TestExecFailurePreservesOneIdempotencyKey(t *testing.T) {
	var mu sync.Mutex
	var keys []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		keys = append(keys, r.Header.Get("Idempotency-Key"))
		mu.Unlock()
		http.Error(w, "backend unavailable", http.StatusServiceUnavailable)
	}))
	defer server.Close()
	key := uuid.NewString()
	var stdout, stderr bytes.Buffer
	code := runCLI(context.Background(), []string{"--api-url", server.URL, "--allow-insecure-localhost", "--json", "--idempotency-key", key, "exec", fixtureSandboxID, "--", "/usr/bin/true"},
		func(name string) string {
			if name == "DARKBLOOM_API_KEY" {
				return fixtureAPIKey
			}
			return ""
		}, &stdout, &stderr)
	if code == 0 {
		t.Fatal("uncertain exec returned success")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(keys) != 1 || keys[0] != key {
		t.Fatalf("exec changed or retried idempotency: %+v", keys)
	}
	var response struct {
		IdempotencyKey string `json:"idempotency_key"`
	}
	if json.Unmarshal(stdout.Bytes(), &response) != nil || response.IdempotencyKey != key {
		t.Fatal("failure omitted recoverable request identity")
	}
}

func TestExecInterruptDuringPollRequestsCancellation(t *testing.T) {
	pollStarted := make(chan struct{})
	var cancellations atomic.Int32
	base := "/v1/sandboxes/" + fixtureSandboxID + "/commands"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == base && r.Method == http.MethodPost {
			_ = json.NewEncoder(w).Encode(commandResponse{&commandRecord{ID: fixtureCommandID, SandboxID: fixtureSandboxID, State: "running"}})
			return
		}
		if r.URL.Path == base+"/"+fixtureCommandID && r.Method == http.MethodGet {
			close(pollStarted)
			<-r.Context().Done()
			return
		}
		if r.URL.Path == base+"/"+fixtureCommandID+"/cancel" {
			cancellations.Add(1)
			_ = json.NewEncoder(w).Encode(commandResponse{&commandRecord{ID: fixtureCommandID, State: "cancelled", CancellationPending: true}})
			return
		}
		http.Error(w, "unknown", 404)
	}))
	defer server.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	app := &cli{client: newSandboxClient(clientConfig{baseURL: server.URL, apiKey: fixtureAPIKey}), stdout: io.Discard, stderr: io.Discard, pollInterval: time.Millisecond}
	finished := make(chan error, 1)
	go func() { finished <- app.execute(ctx, []string{fixtureSandboxID, "--", "/usr/bin/sleep", "60"}) }()
	select {
	case <-pollStarted:
	case <-time.After(time.Second):
		t.Fatal("job status poll did not start")
	}
	cancel()
	select {
	case err := <-finished:
		if err == nil || !strings.Contains(err.Error(), "cancellation requested") {
			t.Fatalf("interrupt outcome: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("interrupt did not finish")
	}
	if cancellations.Load() != 1 {
		t.Fatal("interrupt did not cancel the accepted command")
	}
}

func TestLocalDownloadNeverOverwritesRacingDestination(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "result.bin")
	download, err := newLocalDownload(destination)
	if err != nil {
		t.Fatal(err)
	}
	defer download.close()
	if _, err := download.file.Write([]byte("new contents")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("existing contents"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := download.publish(); err == nil {
		t.Fatal("publication overwrote a racing destination")
	}
	actual, err := os.ReadFile(destination)
	if err != nil || string(actual) != "existing contents" {
		t.Fatal("existing destination changed")
	}
	symlink := filepath.Join(directory, "link.bin")
	if err := os.Symlink(destination, symlink); err != nil {
		t.Fatal(err)
	}
	if _, err := newLocalDownload(symlink); err == nil {
		t.Fatal("symlink destination accepted")
	}
	if _, _, err := openLocalRegularFile(symlink); err == nil {
		t.Fatal("symlink upload source accepted")
	}
	if _, _, err := openLocalRegularFile(directory); err == nil || errors.Is(err, io.EOF) {
		t.Fatal("directory upload source accepted")
	}
}
