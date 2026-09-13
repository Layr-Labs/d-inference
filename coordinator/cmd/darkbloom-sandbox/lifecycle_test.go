package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCleanupFailureRestoredStateStopsWaiting(t *testing.T) {
	for _, action := range []string{"stop", "delete"} {
		t.Run(action, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasPrefix(r.URL.Path, "/v1/sandbox-operations/") {
					_ = json.NewEncoder(w).Encode(operationResponse{Operation: &operationRecord{ID: fixtureOperationID, State: "failed", ErrorCode: "runtime_cleanup_failed"}})
					return
				}
				if r.Method == http.MethodGet {
					// A failed stop restores ready, and failed delete restores stopped.
					// Neither puts the allocation into the generic failed state.
					state := "ready"
					if action == "delete" {
						state = "stopped"
					}
					_ = json.NewEncoder(w).Encode(sandboxRecord{ID: fixtureSandboxID, State: state, ErrorCode: "runtime_cleanup_failed"})
					return
				}
				w.WriteHeader(http.StatusAccepted)
				_ = json.NewEncoder(w).Encode(operationResponse{Operation: &operationRecord{ID: fixtureOperationID, State: "pending"}})
			}))
			defer server.Close()
			app := &cli{client: newSandboxClient(clientConfig{baseURL: server.URL, apiKey: fixtureAPIKey}), stdout: io.Discard, stderr: io.Discard, pollInterval: time.Millisecond}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			err := app.lifecycle(ctx, action, []string{fixtureSandboxID})
			if err == nil || !strings.Contains(err.Error(), "failed") {
				t.Fatalf("cleanup did not report failure: %v", err)
			}
		})
	}
}

func TestStopReplayAfterResumeWaitsForOriginalOperation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost || strings.HasPrefix(r.URL.Path, "/v1/sandbox-operations/") {
			_ = json.NewEncoder(w).Encode(operationResponse{Operation: &operationRecord{ID: fixtureOperationID, State: "stopped"}})
			return
		}
		// A subsequent independent start already resumed the sandbox. Replaying
		// the old stop must return its completed outcome, not stop it again.
		_ = json.NewEncoder(w).Encode(sandboxRecord{ID: fixtureSandboxID, State: "ready"})
	}))
	defer server.Close()
	app := &cli{client: newSandboxClient(clientConfig{baseURL: server.URL, apiKey: fixtureAPIKey}), stdout: io.Discard, stderr: io.Discard, pollInterval: time.Millisecond}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := app.lifecycle(ctx, "stop", []string{fixtureSandboxID}); err != nil {
		t.Fatalf("old stop replay waited on newer runtime state: %v", err)
	}
}
