package api

// Routing-policy integration tests for the routing-failover workstreams
// (WS-R registry policies, WS-T tool-schema normalization). The fake-provider
// harness lives in failover_integration_test.go.
//
//   - Test 4: inference-error cooldown — a provider that returns 2x 5xx within
//     60s enters a 5-minute cooldown and stops receiving dispatches.
//   - Test 5: tools version floor — requests carrying `tools` only route to
//     providers at version >= 0.6.3.
//   - Test 6: template_render_ok gate — tools requests never route to a
//     provider whose advertised model reports template_render_ok=false.
//   - Test 7: NormalizeToolSchemas — JSON-Schema union types in consumer tool
//     definitions are normalized before encryption, so providers receive
//     `"type":"string","nullable":true` instead of `"type":["string","null"]`.
//
// INTEGRATION-NOTE(WS-R): the registry primitives these tests assert through
// (registry/error_cooldown.go RecordInferenceError/RecordInferenceSuccess/
// InferenceErrorCooldownActive(providerID, modelID, shape), registry/request_traits.go
// RequestTraits{HasTools, AvoidVersion} with the "tools" → "0.6.3" floor and
// the template_render_ok gate, protocol.ModelInfo.TemplateRenderOK) have
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

	"github.com/eigeninference/d-inference/coordinator/protocol"
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

// TestInferenceErrorCooldown_ExcludesProvider: provider A (scheduler-preferred
// via DecodeTPS) fails two consecutive requests with a 5xx inference_error;
// both requests transparently fail over to B and succeed. The third request
// must route straight to B — A is in error cooldown and must NOT see a third
// dispatch.
//
// INTEGRATION-NOTE(WS-C/integration): the registry breaker
// (registry/error_cooldown.go) has landed; this test fails until the consumer
// dispatch path actually CALLS RecordInferenceError on provider 5xx terminals
// (A receives the third dispatch too, then errors, then B serves — same
// consumer outcome, one extra dispatch to A). The dispatch-count assertion is
// the contract. RecordInferenceSuccess's cooldown-reset path is not
// exercisable end-to-end without time control; the registry-level assertion
// below covers the active-cooldown query.
func TestInferenceErrorCooldown_ExcludesProvider(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "cooldown-model"

	alwaysError := func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		fp.sendInferenceError(ctx, req, "internal backend error", http.StatusInternalServerError)
	}

	// A is deterministically preferred (DecodeTPS 200 vs 1 → cost gap far
	// beyond the 3s near-tie window), so absent a cooldown every request's
	// FIRST dispatch goes to A.
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: alwaysError,
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	body := buildChatBody(t, model, true, nil)

	// Requests 1 and 2: A errors (5xx), coordinator retries on B, consumer
	// sees success. Each failure feeds the error-cooldown window.
	for i := 1; i <= 2; i++ {
		status, respBody, err := postChat(ctx, ts.URL, "test-key", body)
		if err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
		if status != http.StatusOK {
			t.Fatalf("request %d: status = %d, want 200 (failover to B); body = %s", i, status, respBody)
		}
		if !strings.Contains(respBody, markerFor("provider-b")) {
			t.Fatalf("request %d: response not served by provider-b; body = %s", i, respBody)
		}
		// Let the provider read loop finish recording the error terminal
		// before the next request routes.
		time.Sleep(100 * time.Millisecond)
	}

	if got := pA.dispatchCount(); got != 2 {
		t.Fatalf("provider-a dispatches after 2 requests = %d, want 2 (one failed attempt per request)", got)
	}

	// Request 3: A has 2x 5xx inside 60s → cooldown active → the scheduler
	// must skip A entirely.
	status, respBody, err := postChat(ctx, ts.URL, "test-key", body)
	if err != nil {
		t.Fatalf("request 3: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("request 3: status = %d, want 200; body = %s", status, respBody)
	}
	if !strings.Contains(respBody, markerFor("provider-b")) {
		t.Errorf("request 3: response not served by provider-b; body = %s", respBody)
	}
	if got := pA.dispatchCount(); got != 2 {
		t.Errorf("provider-a dispatches after request 3 = %d, want 2 — cooled-down provider must not see a dispatch", got)
	}
	if got := pB.dispatchCount(); got != 3 {
		t.Errorf("provider-b dispatches = %d, want 3", got)
	}

	// Registry-level assertion via the exported breaker query: the failing
	// pair is quarantined, the healthy pair is not.
	// Shape "base": these requests carry no tools (buildChatBody tools=nil), so
	// the dispatch path records strikes in the base shape bucket.
	if !reg.InferenceErrorCooldownActive(pA.registryID, model, "base") {
		t.Errorf("InferenceErrorCooldownActive(%s, %s, base) = false after 2x 5xx in 60s, want true", pA.registryID, model)
	}
	if reg.InferenceErrorCooldownActive(pB.registryID, model, "base") {
		t.Errorf("InferenceErrorCooldownActive(%s, %s, base) = true for the healthy provider, want false", pB.registryID, model)
	}
}

// ---------------------------------------------------------------------------
// Test 5: tools version floor
// ---------------------------------------------------------------------------

// TestToolsVersionFloor: provider A runs version 0.5.16 (below the 0.6.3
// tools floor) and is scheduler-preferred; provider B runs 0.6.4. A request
// WITH tools must land on B only — A must not even see the dispatch. A
// request WITHOUT tools is unconstrained by the floor and may land on either
// provider (not over-asserted).
//
// INTEGRATION-NOTE(WS-C/integration): the floor itself has landed
// (registry/request_traits.go: capabilityVersionFloors["tools"] = "0.6.3");
// this test fails until the consumer path populates PendingRequest.Traits
// (HasTools) from the parsed request body — until then the tools request
// lands on the preferred 0.5.16 provider.
func TestToolsVersionFloor(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "version-floor-model"

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.5.16", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	// Request WITH tools → must be served by B; A sees no dispatch.
	status, body, err := postChat(ctx, ts.URL, "test-key",
		buildChatBody(t, model, true, weatherTools("string")))
	if err != nil {
		t.Fatalf("tools request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("tools request: status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("provider-b")) {
		t.Errorf("tools request was not served by the >=0.6.3 provider; body = %s", body)
	}
	if got := pA.dispatchCount(); got != 0 {
		t.Errorf("provider-a (0.5.16) received %d dispatch(es) for a tools request, want 0 — version floor must filter at selection time", got)
	}
	if got := pB.dispatchCount(); got != 1 {
		t.Errorf("provider-b dispatches = %d, want 1", got)
	}

	// Request WITHOUT tools → no floor; either provider is acceptable.
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
// populates PendingRequest.Traits. Both providers run 0.6.4 so the version
// floor cannot mask the gate. An ABSENT flag must remain routable for tools
// (old fleet compatibility) — B advertising explicit true plus A explicit
// false isolates the gate's false-branch.
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
// verbatim). The provider runs 0.6.4 with template_render_ok=true so the WS-R
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

// TestToolsFailFastWhenNoCapableProvider: the model's ONLY provider runs
// 0.5.16 — below the tools version floor — so a tools request can never
// route. It must fail fast with a clear error naming tool support, NOT pass
// the trait-blind capacity preflight and queue for 120s into a misleading
// capacity 429. A tool-less request to the same provider must still serve.
// The /v1/messages (Anthropic) surface shares the same gate via
// handleGenericInference.
func TestToolsFailFastWhenNoCapableProvider(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "tools-fail-fast-model"

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.5.16", DecodeTPS: 100,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
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

	// Tool-less request to the same below-floor provider still serves.
	status, body, err = postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("tool-less request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("tool-less request: status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("provider-a")) {
		t.Errorf("tool-less request not served by provider-a; body = %s", body)
	}
	if got := pA.dispatchCount(); got != 1 {
		t.Errorf("provider-a dispatches = %d, want 1 (tool-less only)", got)
	}
}
