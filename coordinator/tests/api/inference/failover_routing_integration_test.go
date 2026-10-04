package inference_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

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
