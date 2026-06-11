package api

// P2 routing-failover integration tests (integrator pass).
//
// These exercise the shape-keyed inference-error breaker and the
// allowlist-aware capability fast-fail end-to-end against a real coordinator
// (httptest server, in-memory store, real registry) and the scripted
// fake-provider harness in failover_integration_test.go. They complement the
// registry-level unit tests in registry/error_cooldown_test.go and
// registry/scheduler_test.go by driving the full consumer dispatch path:
//
//   - TestConstrainedToolsFailFast_AllowlistBelowFloor: a provider_serials
//     allowlist pins routing to a below-tools-floor provider while a capable
//     PUBLIC provider exists. The tools request must fail FAST (503, < ~5s),
//     not pass the trait-blind capacity preflight and queue for 120s — proving
//     HasToolCapableProviderForModel honors allowedSerials.
//   - TestShapeKeyedBreaker_ToolsTrippedBaseStillRoutes: a provider returns 500
//     to TWO tool requests (tripping the "tools" cooldown) but a plain
//     (no-tools) request to the SAME provider still routes and succeeds; and a
//     plain success does NOT lift the tools cooldown (the next tool request
//     avoids that provider). This is the exact prod-incident interleaving the
//     shape-keying closes.
//   - TestCooledToolsPair_ExcludedFromPreflight: after a (provider, model,
//     tools) cooldown is armed, a fresh tools request whose ONLY tools-capable
//     provider is the cooled one fast-fails (no 120s queue) — the shape-keyed
//     cooldown is consulted inside QuickCapacityCheck / the capability gate.
//
// INTEGRATION-NOTE: all three depend on both halves of the routing-failover
// work — the registry shape-keyed breaker / allowlist-aware capability checks
// AND the consumer dispatch wiring (PendingRequest.Traits from the parsed body,
// RecordInferenceError on terminals, allowedProviderSerials into the
// capability fast-fail). They fail against either half alone.
//
// The speculative "both racers stall after the preamble feeds 504 into the
// breaker" arm (consumer.go ~2573) is NOT covered here: the both-missed arm
// only fires after the race deadline is extended by preambleContentTimeout
// (90s), which is impractical for a fast, non-flaky integration test. The
// 504-feeds-breaker contract on that arm is instead exercised at the unit
// level (registry/error_cooldown_test.go counts 504 as a strike) and shares
// the same noteInferenceError(504) call as the single-provider accepted-timeout
// path; see the integrator report.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// buildChatBodyWithSerials is buildChatBody plus a provider_serials allowlist,
// so a request can constrain routing to a specific attested-serial set exactly
// as a sandbox/allowlisted account does.
func buildChatBodyWithSerials(t *testing.T, model string, stream bool, tools []map[string]any, serials []string) string {
	t.Helper()
	body := map[string]any{
		"model":      model,
		"messages":   []map[string]any{{"role": "user", "content": "p2 failover test prompt"}},
		"stream":     stream,
		"max_tokens": 64,
	}
	if tools != nil {
		body["tools"] = tools
	}
	if len(serials) > 0 {
		body["provider_serials"] = serials
	}
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal chat body: %v", err)
	}
	return string(data)
}

// bodyHasTools reports whether a decrypted request body carries a non-empty
// tools array — the dimension a shape-aware fake provider branches on.
func bodyHasTools(body []byte) bool {
	if body == nil {
		return false
	}
	var parsed struct {
		Tools []json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return false
	}
	return len(parsed.Tools) > 0
}

// ---------------------------------------------------------------------------
// Test: constrained tools fail-fast when the allowlist names only a
// below-floor provider, even though a capable public provider exists.
// ---------------------------------------------------------------------------

func TestConstrainedToolsFailFast_AllowlistBelowFloor(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "constrained-tools-model"

	// Sandbox provider: in the allowlist, but below the 0.6.3 tools floor — it
	// can never serve a tools request.
	sandbox := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "sandbox", Version: "0.5.16", DecodeTPS: 100, Serial: "SANDBOX-1",
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	// Public provider: tool-capable (0.6.4) but NOT in the allowlist, so it must
	// not satisfy the constrained request.
	public := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "public", Version: "0.6.4", DecodeTPS: 200, Serial: "PUBLIC-1",
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	// Tools request pinned to the sandbox serial → fast clean 503, no dispatch.
	start := time.Now()
	status, body, err := postChat(ctx, ts.URL, "test-key",
		buildChatBodyWithSerials(t, model, true, weatherTools("string"), []string{"SANDBOX-1"}))
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("constrained tools request: %v", err)
	}
	if status != http.StatusServiceUnavailable {
		t.Errorf("constrained tools request: status = %d, want 503; body = %s", status, body)
	}
	if !strings.Contains(body, "tool calls") {
		t.Errorf("error body does not name tool support as the cause; body = %s", body)
	}
	if elapsed > 5*time.Second {
		t.Errorf("constrained tools fail-fast took %s — the request queued instead of failing fast (allowedSerials not honored?)", elapsed)
	}
	if got := sandbox.dispatchCount(); got != 0 {
		t.Errorf("sandbox (below floor) received %d dispatch(es), want 0", got)
	}
	if got := public.dispatchCount(); got != 0 {
		t.Errorf("public provider received %d dispatch(es) for an allowlist-pinned request, want 0 — a public provider must not satisfy a constrained tools request", got)
	}

	// Sanity: the SAME tools request WITHOUT the allowlist routes to the public
	// capable provider — proving the 503 above is the allowlist constraint, not
	// a missing-capability false positive.
	status, body, err = postChat(ctx, ts.URL, "test-key",
		buildChatBody(t, model, true, weatherTools("string")))
	if err != nil {
		t.Fatalf("unconstrained tools request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("unconstrained tools request: status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("public")) {
		t.Errorf("unconstrained tools request not served by the public capable provider; body = %s", body)
	}
}

// ---------------------------------------------------------------------------
// Test: shape-keyed breaker — tools cooldown does not deroute base traffic,
// and a base success does not lift the tools cooldown.
// ---------------------------------------------------------------------------

// shapeAwareScript errors (500) on tool-bearing requests and serves plain
// (no-tools) requests fully — the failure shape that, under a shared
// (non-shape-keyed) counter, would have its tools strikes reset by interleaved
// clean base successes (the prod incident).
func shapeAwareScript(model string) inferenceScript {
	return func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, body []byte) {
		if bodyHasTools(body) {
			fp.sendRoleChunk(ctx, req, model)
			time.Sleep(20 * time.Millisecond)
			fp.sendInferenceError(ctx, req, "simulated tool-template crash", http.StatusInternalServerError)
			return
		}
		fp.serveFull(ctx, req, model, markerFor(fp.name))
	}
}

func TestShapeKeyedBreaker_ToolsTrippedBaseStillRoutes(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()

	model := "shape-breaker-model"

	// A is deterministically preferred (high TPS) so it gets the first dispatch.
	// It crashes on tools, serves base. B is a tool-capable fallback.
	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.6.4", DecodeTPS: 200, Serial: "A-1",
		Models: []failoverModelSpec{{ID: model}}, Script: shapeAwareScript(model),
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.6.4", DecodeTPS: 1, Serial: "B-1",
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	toolBody := buildChatBody(t, model, true, weatherTools("string"))

	// Two tool requests: A errors each time (failing over to B), tripping the
	// (A, model, tools) cooldown.
	for i := 1; i <= 2; i++ {
		status, body, err := postChat(ctx, ts.URL, "test-key", toolBody)
		if err != nil {
			t.Fatalf("tool request %d: %v", i, err)
		}
		if status != http.StatusOK {
			t.Fatalf("tool request %d: status = %d, want 200 (failover to B); body = %s", i, status, body)
		}
		if !strings.Contains(body, markerFor("provider-b")) {
			t.Fatalf("tool request %d not served by provider-b; body = %s", i, body)
		}
		time.Sleep(100 * time.Millisecond)
	}

	// The tools bucket for A is now cooled; the base bucket is not.
	if !reg.InferenceErrorCooldownActive(pA.registryID, model, "tools") {
		t.Errorf("(A, model, tools) cooldown not active after 2x 5xx tool failures")
	}
	if reg.InferenceErrorCooldownActive(pA.registryID, model, "base") {
		t.Errorf("(A, model, base) cooldown active — a tools failure must not deroute base traffic")
	}

	aBefore := pA.dispatchCount()

	// A PLAIN (no-tools) request to the SAME model must still route to A (its
	// base bucket is healthy) and succeed.
	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("plain request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("plain request: status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("provider-a")) {
		t.Errorf("plain request not served by provider-a — the tools cooldown wrongly deroutes base traffic; body = %s", body)
	}
	if got := pA.dispatchCount(); got != aBefore+1 {
		t.Errorf("provider-a base dispatches = %d, want %d (the plain request must reach A)", got, aBefore+1)
	}
	time.Sleep(100 * time.Millisecond)

	// The base success must NOT lift the tools cooldown.
	if !reg.InferenceErrorCooldownActive(pA.registryID, model, "tools") {
		t.Errorf("(A, model, tools) cooldown lifted by a base success — base success must not clear the tools bucket")
	}

	// A fresh tools request must therefore still avoid A and land on B.
	bBefore := pB.dispatchCount()
	status, body, err = postChat(ctx, ts.URL, "test-key", toolBody)
	if err != nil {
		t.Fatalf("post-base tool request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("post-base tool request: status = %d, want 200; body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("provider-b")) {
		t.Errorf("post-base tool request not served by B — A's tools cooldown must still hold; body = %s", body)
	}
	if got := pB.dispatchCount(); got != bBefore+1 {
		t.Errorf("provider-b tool dispatches = %d, want %d", got, bBefore+1)
	}
}

// ---------------------------------------------------------------------------
// Test: a cooled (provider, model, tools) pair is excluded from the preflight,
// so a fresh tools request whose only capable provider is cooled fast-fails
// instead of queueing to timeout.
// ---------------------------------------------------------------------------

func TestCooledToolsPair_ExcludedFromPreflight(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	model := "cooled-preflight-model"

	// The ONLY tool-capable provider for this model. It crashes on tools.
	only := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "only", Version: "0.6.4", DecodeTPS: 100, Serial: "ONLY-1",
		Models: []failoverModelSpec{{ID: model}}, Script: shapeAwareScript(model),
	})

	toolBody := buildChatBody(t, model, true, weatherTools("string"))

	// Two tool requests fail (no failover target exists), each surfacing an
	// error to the consumer, and arm the (only, model, tools) cooldown.
	for i := 1; i <= 2; i++ {
		_, _, err := postChat(ctx, ts.URL, "test-key", toolBody)
		if err != nil {
			t.Fatalf("tool request %d: %v", i, err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !reg.InferenceErrorCooldownActive(only.registryID, model, "tools") {
		t.Fatalf("(only, model, tools) cooldown not active after 2x 5xx — cannot test preflight exclusion")
	}

	dispatchesBefore := only.dispatchCount()

	// A fresh tools request: the only capable provider is cooled for tools, so
	// QuickCapacityCheck (traits HasTools) + HasToolCapableProviderForModel must
	// report no candidate and the request must fail FAST, not queue 120s.
	start := time.Now()
	status, body, err := postChat(ctx, ts.URL, "test-key", toolBody)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("post-cooldown tool request: %v", err)
	}
	if status == http.StatusOK {
		t.Errorf("post-cooldown tool request unexpectedly succeeded; the cooled pair should not serve; body = %s", body)
	}
	if elapsed > 10*time.Second {
		t.Errorf("post-cooldown tool request took %s — the cooled pair was not excluded from preflight (queued to timeout)", elapsed)
	}
	// The cooled pair must not receive another dispatch for the cooled shape.
	if got := only.dispatchCount(); got != dispatchesBefore {
		t.Errorf("cooled provider received %d dispatch(es) post-cooldown, want %d — cooled (provider,model,tools) must be skipped", got-dispatchesBefore, 0)
	}

	// A PLAIN request still routes to the same provider (its base bucket is
	// healthy) — the cooldown is shape-scoped, confirming the fast-fail above is
	// the tools cooldown, not a dead provider.
	status, body, err = postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("plain request: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("plain request: status = %d, want 200 (base bucket healthy); body = %s", status, body)
	}
	if !strings.Contains(body, markerFor("only")) {
		t.Errorf("plain request not served by the only provider; body = %s", body)
	}
}
