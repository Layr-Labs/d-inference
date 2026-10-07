package inference_test

// Routing-policy integration tests for the routing-failover workstreams
// (WS-R registry policies, WS-T tool-schema normalization). The fake-provider
// harness lives in failover_integration_test.go.
//
//   - Test 4: inference-error cooldown — a provider that returns 2x 5xx within
//     60s enters a 5-minute cooldown and stops receiving dispatches.
//   - Test 6: template_render_ok gate — tools requests never route to a
//     provider whose advertised model reports template_render_ok=false.
//   - Test 7: NormalizeToolSchemas — JSON-Schema union types in consumer tool
//     definitions are normalized before encryption, so providers receive
//     `"type":"string","nullable":true` instead of `"type":["string","null"]`.
//
// INTEGRATION-NOTE(WS-R): the registry primitives these tests assert through
// (registry/error_cooldown.go RecordInferenceError/RecordInferenceSuccess/
// InferenceErrorCooldownActive(providerID, modelID, shape), registry/request_traits.go
// RequestTraits{HasTools, AvoidVersion} and the template_render_ok gate,
// protocol.ModelInfo.TemplateRenderOK) have
// LANDED. These tests fail until the consumer-side wiring lands: populating
// PendingRequest.Traits from the parsed body and calling
// RecordInferenceError/RecordInferenceSuccess on dispatch terminals (WS-C /
// integration). The cooldown query is bound directly below.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Tools fixtures
// ---------------------------------------------------------------------------

// weatherTools returns an OpenAI tools array with a single function whose
// `city` parameter has the given JSON-Schema "type" value. Pass "string" for
// a plain schema, or []any{"string","null"} to exercise normalization.
func weatherTools(cityType any) []map[string]any {
	return []map[string]any{{
		"type": "function",
		"function": map[string]any{
			"name":        "get_weather",
			"description": "Get the current weather for a city",
			"parameters": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"city": map[string]any{
						"type":        cityType,
						"description": "City name",
					},
				},
				"required": []string{"city"},
			},
		},
	}}
}

// ---------------------------------------------------------------------------
// Test 4: inference-error cooldown excludes the failing provider
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Test 6: template_render_ok gate
// ---------------------------------------------------------------------------

// TestTemplateRenderOKGate: provider A advertises the model with
// template_render_ok=false (its chat-template self-check failed for tool
// calls); provider B advertises true. A tools request must route to B only; a
// tool-less request is unaffected by the gate.
//
// INTEGRATION-NOTE(WS-C/integration): the gate has landed registry-side
// (protocol.ModelInfo.TemplateRenderOK + the HasTools render-broken check in
// registry/request_traits.go); this test fails until the consumer path
// populates PendingRequest.Traits. An ABSENT flag must remain routable for
// tools (no opinion) — B advertising explicit true plus A explicit false
// isolates the gate's false-branch.
func TestTemplateRenderOKGate(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "render-gate-model"
	renderOK := true
	renderBroken := false

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model, TemplateRenderOK: &renderBroken}},
		Script: fullServeScript(model),
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model, TemplateRenderOK: &renderOK}},
		Script: fullServeScript(model),
	})

	// Tools request → only the render-ok provider may serve it.
	status, body, err := postChat(ctx, ts.URL, "test-key",
		buildChatBody(t, model, true, weatherTools("string")))
	if err != nil {
		t.Fatalf("tools request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("tools request: status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("provider-b")) {
		t.Errorf("tools request was not served by the template_render_ok provider; body = %s", body)
	}
	if got := pA.dispatchCount(); got != 0 {
		t.Errorf("provider-a (template_render_ok=false) received %d dispatch(es) for a tools request, want 0", got)
	}
	if got := pB.dispatchCount(); got != 1 {
		t.Errorf("provider-b dispatches = %d, want 1", got)
	}

	// Tool-less request → the gate does not apply; either provider may serve.
	status, body, err = postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("tool-less request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("tool-less request: status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, "content-from-") {
		t.Errorf("tool-less request produced no provider content; body = %s", body)
	}
}

// ---------------------------------------------------------------------------
// Test 7: normalized tool schemas reach the provider
// ---------------------------------------------------------------------------

// TestNormalizedToolsReachProvider: the consumer defines a tool parameter with
// a JSON-Schema union type `"type":["string","null"]`. The coordinator must
// normalize tool schemas BEFORE encrypting the request body, so the provider
// decrypts a schema with `"type":"string"` and `"nullable":true` (the form MLX
// chat templates can render).
//
// INTEGRATION-NOTE(WS-T): depends on the orchestrator wiring
// NormalizeToolSchemas into the consumer dispatch path pre-encryption. Fails
// against the pre-workstream coordinator (the union type passes through
// verbatim). The provider advertises template_render_ok=true so the WS-R
// tools gates cannot block the dispatch once they land.
func TestNormalizedToolsReachProvider(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "tool-normalize-model"
	renderOK := true

	fp := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model, TemplateRenderOK: &renderOK}},
		Script: fullServeScript(model),
	})

	status, respBody, err := postChat(ctx, ts.URL, "test-key",
		buildChatBody(t, model, true, weatherTools([]any{"string", "null"})))
	if err != nil {
		t.Fatalf("tools request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("tools request: status = %d, want 200; body = %s", status, respBody)
	}

	// The provider captured the decrypted request body it received.
	var captured []byte
	select {
	case captured = <-fp.bodies:
	case <-time.After(5 * time.Second):
		t.Fatal("provider did not capture a decrypted request body")
	}
	if captured == nil {
		t.Fatal("provider failed to decrypt the request body")
	}

	var decoded struct {
		Tools []struct {
			Function struct {
				Parameters struct {
					Properties map[string]map[string]any `json:"properties"`
				} `json:"parameters"`
			} `json:"function"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(captured, &decoded); err != nil {
		t.Fatalf("decrypted body is not valid JSON: %v; body = %s", err, captured)
	}
	if len(decoded.Tools) != 1 {
		t.Fatalf("decrypted body has %d tools, want 1; body = %s", len(decoded.Tools), captured)
	}
	city, ok := decoded.Tools[0].Function.Parameters.Properties["city"]
	if !ok {
		t.Fatalf("decrypted tool schema missing the city property; body = %s", captured)
	}
	if got, want := city["type"], any("string"); got != want {
		t.Errorf("provider received city.type = %v (%T), want %q — union type was not normalized pre-encryption", got, got, want)
	}
	if got, want := city["nullable"], any(true); got != want {
		t.Errorf("provider received city.nullable = %v (%T), want true — null member of the union must become nullable:true", got, got)
	}
}

// ---------------------------------------------------------------------------
// Test 9: tools fail-fast when the whole pool is trait-gated
// ---------------------------------------------------------------------------

// postInference sends a request body to an arbitrary inference endpoint
// (e.g. /v1/messages) and drains the response — postChat's generalization for
// the non-chat-completions handlers.
func postInference(ctx context.Context, tsURL, endpoint, apiKey, body string) (int, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, tsURL+endpoint, strings.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(respBody), nil
}

// TestToolsFailFastWhenNoCapableProvider: the model's ONLY provider advertises
// it with template_render_ok=false — its chat-template self-check crashed — so
// a tools request can never route. It must fail fast with a clear error naming
// tool support, NOT pass the trait-blind capacity preflight and queue for 120s
// into a misleading capacity 429. The /v1/messages (Anthropic) surface shares
// the same gate via handleGenericInference. (A render-broken build is fenced
// for every request shape, so no tool-less control is possible on this
// fixture; TestTemplateRenderOKGate covers routing to a healthy build.)
func TestToolsFailFastWhenNoCapableProvider(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "tools-fail-fast-model"
	renderBroken := false

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.9.9", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model, TemplateRenderOK: &renderBroken}},
		Script: fullServeScript(model),
	})

	// Tools request → fast, clean 503 naming the real cause.
	start := time.Now()
	status, body, err := postChat(ctx, ts.URL, "test-key",
		buildChatBody(t, model, true, weatherTools("string")))
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("tools request: %v", err)
	}
	if status != http.StatusServiceUnavailable {
		t.Errorf("tools request: status = %d, want 503; body = %s", status, body)
	}
	if !strings.Contains(body, "tool calls") {
		t.Errorf("error body does not name tool support as the cause; body = %s", body)
	}
	if elapsed > 5*time.Second {
		t.Errorf("tools fail-fast took %s — the request queued instead of failing fast", elapsed)
	}
	if got := pA.dispatchCount(); got != 0 {
		t.Errorf("provider-a received %d dispatch(es) for an unroutable tools request, want 0", got)
	}

	// Anthropic surface: same gate, same fast clean error.
	anthropicBody := `{"model":"` + model + `","max_tokens":64,` +
		`"messages":[{"role":"user","content":"fail fast"}],` +
		`"tools":[{"name":"get_weather","description":"weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}}}}]}`
	start = time.Now()
	status, body, err = postInference(ctx, ts.URL, "/v1/messages", "test-key", anthropicBody)
	elapsed = time.Since(start)
	if err != nil {
		t.Fatalf("anthropic tools request: %v", err)
	}
	if status != http.StatusServiceUnavailable {
		t.Errorf("anthropic tools request: status = %d, want 503; body = %s", status, body)
	}
	if !strings.Contains(body, "tool calls") {
		t.Errorf("anthropic error body does not name tool support; body = %s", body)
	}
	if elapsed > 5*time.Second {
		t.Errorf("anthropic tools fail-fast took %s — queued instead of failing fast", elapsed)
	}
	if got := pA.dispatchCount(); got != 0 {
		t.Errorf("provider-a received %d dispatch(es) for an unroutable anthropic tools request, want 0", got)
	}
}
