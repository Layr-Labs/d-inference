package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	runtimeDefaultsAlias         = "runtime-defaults-alias"
	runtimeDefaultsDesiredModel  = "runtime-defaults-desired"
	runtimeDefaultsPreviousModel = "runtime-defaults-previous"
)

type runtimeDefaultsAliasHarness struct {
	ctx       context.Context
	server    *httptest.Server
	providers []*failoverProvider
}

func newRuntimeDefaultsAliasHarness(
	t *testing.T,
	desiredRuntime, previousRuntime map[string]any,
	previousScripts ...inferenceScript,
) runtimeDefaultsAliasHarness {
	t.Helper()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	seedRuntimeDefaultsModel(t, st, runtimeDefaultsDesiredModel, desiredRuntime)
	seedRuntimeDefaultsModel(t, st, runtimeDefaultsPreviousModel, previousRuntime)

	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 30 * time.Second
	srv.SyncModelCatalog()

	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)

	desired := registerBuildsProvider(srv, "runtime-defaults-desired-provider", runtimeDefaultsDesiredModel)
	desired.Mu().Lock()
	desired.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 1_000
	desired.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 1_000
	desired.Mu().Unlock()

	if len(previousScripts) == 0 {
		previousScripts = []inferenceScript{fullServeScript(runtimeDefaultsPreviousModel)}
	}
	providers := make([]*failoverProvider, 0, len(previousScripts))
	for index, script := range previousScripts {
		providers = append(providers, startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
			Name:      fmt.Sprintf("runtime-defaults-previous-provider-%d", index),
			Version:   "0.6.4",
			DecodeTPS: 100,
			Models:    []failoverModelSpec{{ID: runtimeDefaultsPreviousModel}},
			Script:    script,
		}))
	}
	reg.SetModelAliases(map[string]registry.AliasTarget{
		runtimeDefaultsAlias: {
			Desired:  runtimeDefaultsDesiredModel,
			Previous: runtimeDefaultsPreviousModel,
		},
	})

	return runtimeDefaultsAliasHarness{ctx: ctx, server: ts, providers: providers}
}

func seedRuntimeDefaultsModel(t *testing.T, st store.Store, model string, runtimeParameters map[string]any) {
	t.Helper()
	entry := &store.ModelRegistryEntry{
		ID: model, DisplayName: model, Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 8192, MinRAMGB: 24,
		Capabilities: []string{"chat"}, Status: "active",
		RuntimeParameters: runtimeParameters,
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: model, Version: "v1", R2Prefix: modelR2Prefix(model, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatal(err)
	}
	if err := st.PromoteModelVersion(model, "v1"); err != nil {
		t.Fatal(err)
	}
}

func postRuntimeDefaultsEndpoint(t *testing.T, harness runtimeDefaultsAliasHarness, path, body string) {
	t.Helper()
	request, err := http.NewRequestWithContext(
		harness.ctx, http.MethodPost, harness.server.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer test-key")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	responseBody, readErr := io.ReadAll(response.Body)
	response.Body.Close()
	if readErr != nil {
		t.Fatal(readErr)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", response.StatusCode, responseBody)
	}
}

func readRuntimeDefaultsProviderBody(t *testing.T, provider *failoverProvider) map[string]json.RawMessage {
	t.Helper()
	var body []byte
	select {
	case body = <-provider.bodies:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for fallback provider body")
	}
	if body == nil {
		t.Fatal("fallback provider could not decrypt request body")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		t.Fatalf("decode fallback provider body: %v\n%s", err, body)
	}
	return fields
}

func assertRuntimeDefaultField(t *testing.T, fields map[string]json.RawMessage, key, want string, exists bool) {
	t.Helper()
	raw, gotExists := fields[key]
	if gotExists != exists {
		t.Fatalf("%s presence = %v, want %v: %s", key, gotExists, exists, raw)
	}
	if !exists {
		return
	}
	var got string
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("decode %s: %v", key, err)
	}
	if got != want {
		t.Fatalf("%s = %q, want %q", key, got, want)
	}
}

func TestAliasFallbackRecomputesRuntimeDefaultsForEveryEndpoint(t *testing.T) {
	desiredRuntime := map[string]any{
		"reasoning_parser": "desired-reasoning",
		"tool_call_parser": "desired-tools",
		"provider_only":    "must-not-leak",
	}
	tests := []struct {
		name            string
		path            string
		body            string
		previousRuntime map[string]any
		wantReasoning   string
		wantTools       string
		wantParsers     bool
	}{
		{
			name: "chat recomputes different defaults",
			path: "/v1/chat/completions",
			body: `{"model":"runtime-defaults-alias","messages":[{"role":"user","content":"hello"}],"max_tokens":32,"stream":true}`,
			previousRuntime: map[string]any{
				"reasoning_parser": "previous-reasoning",
				"tool_call_parser": "previous-tools",
			},
			wantReasoning: "previous-reasoning",
			wantTools:     "previous-tools",
			wantParsers:   true,
		},
		{
			name:            "responses removes absent defaults",
			path:            "/v1/responses",
			body:            `{"model":"runtime-defaults-alias","input":"hello","max_output_tokens":32,"stream":true}`,
			previousRuntime: nil,
		},
		{
			name: "messages keeps same defaults after lowering",
			path: "/v1/messages",
			body: `{"model":"runtime-defaults-alias","messages":[{"role":"user","content":"hello"}],"max_tokens":32,"stream":true}`,
			previousRuntime: map[string]any{
				"reasoning_parser": "desired-reasoning",
				"tool_call_parser": "desired-tools",
			},
			wantReasoning: "desired-reasoning",
			wantTools:     "desired-tools",
			wantParsers:   true,
		},
		{
			name: "completions preserves explicit overrides after lowering",
			path: "/v1/completions",
			body: `{"model":"runtime-defaults-alias","prompt":"hello","reasoning_parser":"caller-reasoning","tool_call_parser":"caller-tools","max_tokens":32,"stream":true}`,
			previousRuntime: map[string]any{
				"reasoning_parser": "previous-reasoning",
				"tool_call_parser": "previous-tools",
			},
			wantReasoning: "caller-reasoning",
			wantTools:     "caller-tools",
			wantParsers:   true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			harness := newRuntimeDefaultsAliasHarness(t, desiredRuntime, test.previousRuntime)
			postRuntimeDefaultsEndpoint(t, harness, test.path, test.body)
			fields := readRuntimeDefaultsProviderBody(t, harness.providers[0])

			assertRuntimeDefaultField(t, fields, "reasoning_parser", test.wantReasoning, test.wantParsers)
			assertRuntimeDefaultField(t, fields, "tool_call_parser", test.wantTools, test.wantParsers)
			assertRuntimeDefaultField(t, fields, "provider_only", "", false)
			assertRuntimeDefaultField(t, fields, "endpoint", "", false)
			assertRuntimeDefaultField(t, fields, "input", "", false)
			assertRuntimeDefaultField(t, fields, "prompt", "", false)

			var gotModel string
			if err := json.Unmarshal(fields["model"], &gotModel); err != nil {
				t.Fatal(err)
			}
			if gotModel != runtimeDefaultsPreviousModel {
				t.Fatalf("provider model = %q, want %q", gotModel, runtimeDefaultsPreviousModel)
			}
		})
	}
}

func TestAliasFallbackRetryKeepsRecomputedRuntimeDefaults(t *testing.T) {
	desiredRuntime := map[string]any{
		"reasoning_parser": "desired-reasoning",
		"tool_call_parser": "desired-tools",
	}
	previousRuntime := map[string]any{
		"reasoning_parser": "previous-reasoning",
		"tool_call_parser": "previous-tools",
	}
	dispatches := &dispatchRecorder{}
	harness := newRuntimeDefaultsAliasHarness(
		t,
		desiredRuntime,
		previousRuntime,
		failFirstScript(dispatches, runtimeDefaultsPreviousModel, "error"),
		failFirstScript(dispatches, runtimeDefaultsPreviousModel, "error"),
	)
	postRuntimeDefaultsEndpoint(t, harness, "/v1/chat/completions",
		`{"model":"runtime-defaults-alias","messages":[{"role":"user","content":"hello"}],"max_tokens":32,"stream":true}`)

	if sequence := dispatches.sequence(); len(sequence) != 2 {
		t.Fatalf("dispatch sequence = %v, want one fallback attempt plus one retry", sequence)
	}
	for _, provider := range harness.providers {
		fields := readRuntimeDefaultsProviderBody(t, provider)
		assertRuntimeDefaultField(t, fields, "reasoning_parser", "previous-reasoning", true)
		assertRuntimeDefaultField(t, fields, "tool_call_parser", "previous-tools", true)
	}
}
