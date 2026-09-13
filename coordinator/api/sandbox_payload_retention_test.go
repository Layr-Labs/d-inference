package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/sandboxcontrol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

func TestSandboxCommandAPIReportsExpiredPayloadAndPreservesReplay(t *testing.T) {
	server := newSandboxHostTestServer(t)
	sandbox, _ := seedSandboxAPIResource(t, server.store, false)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	key := uuid.NewString()
	request := sandboxcontrol.CommandRequest{IdempotencyKey: key, Arguments: []string{"/usr/bin/printf", "private-argument"}, Environment: map[string]string{"TOKEN": "private-environment"}, TimeoutSeconds: 60}
	command, err := server.sandboxes.Execute(ctx, sandbox.AccountID, sandbox.ID, request)
	if err != nil {
		t.Fatal(err)
	}
	output, code := "private-output", int32(0)
	if _, err := server.store.ApplySandboxCommandUpdate(ctx, store.SandboxCommandUpdate{CommandID: command.ID, SandboxID: command.SandboxID,
		Generation: command.Generation, FencingToken: command.FencingToken, State: store.SandboxCommandSucceeded,
		ExitCode: &code, StandardOutput: &output, StandardError: &output, UpdatedAt: now.Add(time.Second)}); err != nil {
		t.Fatal(err)
	}
	if _, err := server.store.RedactSandboxCommandPayloads(ctx, now.Add(time.Hour), now.Add(2*time.Hour), 32); err != nil {
		t.Fatal(err)
	}
	path := "/v1/sandboxes/" + sandbox.ID + "/commands/" + command.ID
	response := sandboxLocalAPIRequest(server, http.MethodGet, path, "test-key")
	if response.Code != 200 || response.Header().Get("Cache-Control") != "no-store" ||
		!strings.Contains(response.Body.String(), `"payload_expired":true`) || strings.Contains(response.Body.String(), "private-") || strings.Contains(response.Body.String(), "request_digest") {
		t.Fatalf("expired response: %d %s", response.Code, response.Body.String())
	}
	body, _ := json.Marshal(sandboxCommandRequest{Arguments: request.Arguments, Environment: request.Environment, TimeoutSeconds: 60})
	replay := httptest.NewRequest(http.MethodPost, "/v1/sandboxes/"+sandbox.ID+"/commands", bytes.NewReader(body))
	replay.Header.Set("Authorization", "Bearer test-key")
	replay.Header.Set("Idempotency-Key", key)
	retried := httptest.NewRecorder()
	server.Handler().ServeHTTP(retried, replay)
	if retried.Code != http.StatusAccepted || !strings.Contains(retried.Body.String(), command.ID) || !strings.Contains(retried.Body.String(), `"payload_expired":true`) {
		t.Fatalf("replay response: %d %s", retried.Code, retried.Body.String())
	}
	otherKey, err := server.store.CreateKeyForAccount("other-retention-account")
	if err != nil {
		t.Fatal(err)
	}
	if other := sandboxLocalAPIRequest(server, http.MethodGet, path, otherKey); other.Code != http.StatusNotFound {
		t.Fatal("expired command crossed account boundary")
	}
}

func TestSandboxPayloadRetentionConfigurationRequiresFinitePositiveDuration(t *testing.T) {
	const name = "EIGENINFERENCE_SANDBOX_COMMAND_PAYLOAD_RETENTION"
	for _, value := range []string{"0", "-1h", "forever", "721h"} {
		t.Setenv(name, value)
		if config := ReadServerConfig(); config.Check() == nil {
			t.Fatalf("invalid retention accepted: %s", value)
		}
	}
	t.Setenv(name, "48h")
	config := ReadServerConfig()
	if config.Check() != nil || config.SandboxService.CommandPayloadRetention != 48*time.Hour {
		t.Fatal("configured finite retention was not loaded")
	}
	t.Setenv(name, "")
	if config := ReadServerConfig(); config.SandboxService.CommandPayloadRetention != 24*time.Hour {
		t.Fatal("default retention is not24h")
	}
}
