package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// End-to-end coverage for the smart servability gate (early-429 admission).
//
// The gate (s.shedIfUnservable, wired into handleChatCompletions' public
// preflight) asks registry.PredictServable whether the fleet could STRUCTURALLY
// serve a request of this size before admitting it. When the gate is ON (the
// default — EIGENINFERENCE_SERVABILITY_GATE unset behaves as true) and the
// request is unservable it returns an uptime-neutral 429 + Retry-After (so
// OpenRouter fails over) instead of admitting it and letting a provider 5xx.
// When explicitly disabled (EIGENINFERENCE_SERVABILITY_GATE=false) it is a
// no-op and the request flows into the normal capacity ladder.
//
// The A/B tests below use an identical server + provider + oversized request,
// the ONLY difference being the gate state (on / env-default-on / env-off).

// servabilityHarness builds the shared fixture: a server with one routable,
// model-resident provider whose single slot advertises a deliberately small
// structural token budget (4096), plus an oversized chat request whose
// (estimated prompt + max_tokens) far exceeds that budget.
func servabilityHarness(t *testing.T) (*Server, *http.Request) {
	t.Helper()
	return servabilityHarnessWithBudget(t, 4096, 0)
}

// servabilityHarnessWithBudget is servabilityHarness with the provider slot's
// token-budget ceiling and live usage under test control, so tests can shape
// structural impossibility (ceiling < request) vs transient fullness (ceiling
// fits, ceiling − used doesn't) against the same ~10,064-token request.
//
// The provider setup mirrors the routing tests in consumer_test.go:
// registerBuildsProvider yields a trusted, challenge-fresh, runtime-verified
// provider that passes the same gates real routing applies. The only addition is
// setting the resident slot's ActiveTokenBudgetMax/Used — PredictServable's
// tier-2 (prompt_too_long) reads the ceiling, and the capacity path's
// freeMemoryAdmits reads the live remainder.
//
// queue-before-shed is disabled so requests that reach the capacity ladder
// fast-shed with an immediate capacity 429 instead of spilling into the 120s
// dispatch queue — keeping the tests deterministic and fast. It has no bearing
// on a gate-ON shed, which returns before that branch is reached.
func servabilityHarnessWithBudget(t *testing.T, budgetMax, budgetUsed int64) (*Server, *http.Request) {
	t.Helper()
	t.Setenv("EIGENINFERENCE_QUEUE_BEFORE_SHED", "false")

	srv, _ := testServer(t)
	const model = "servability-budget-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})

	p := registerBuildsProvider(srv, "servability-budget-provider", model)
	p.Mu().Lock()
	// Resident slot ("running" => modelLoaded): PredictServable uses the
	// reported ActiveTokenBudgetMax for resident slots rather than a cold
	// estimate.
	p.BackendCapacity.Slots[0].State = "running"
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = budgetMax
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = budgetUsed
	p.Mu().Unlock()

	// ~40,000 chars => ~10,000 estimated prompt tokens (the len/4 routing
	// heuristic in estimatePromptTokens); with max_tokens 64 the request needs
	// ~10,064 tokens, far beyond the 4096 budget, so it is structurally
	// unservable on this (only) provider.
	hugePrompt := strings.Repeat("x", 40000)
	reqBody, err := json.Marshal(map[string]any{
		"model":      model,
		"messages":   []any{map[string]any{"role": "user", "content": hugePrompt}},
		"max_tokens": 64,
	})
	if err != nil {
		t.Fatalf("marshal request body: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(string(reqBody)))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	return srv, req
}

// TestServabilityGateShedsUnservable429 pins the gate-ON behaviour: the oversized
// request is shed at preflight with a 429 + Retry-After and the servability body,
// before any dispatch.
func TestServabilityGateShedsUnservable429(t *testing.T) {
	srv, req := servabilityHarness(t)
	srv.SetServabilityGate(true)

	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d; body = %s", w.Code, http.StatusTooManyRequests, w.Body.String())
	}
	if got := w.Header().Get("Retry-After"); got == "" {
		t.Fatal("Retry-After header missing on servability 429")
	}

	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("unmarshal body %q: %v", w.Body.String(), err)
	}
	if body.Error.Code != "rate_limit_exceeded" {
		t.Fatalf("error.code = %q, want rate_limit_exceeded; body = %s", body.Error.Code, w.Body.String())
	}
	// Pin the servability gate specifically (tier-2 prompt_too_long), not a
	// generic capacity 429: only this gate emits the "largest provider token
	// budget" detail. modelMaxContext is 0 here (no store registry record), so
	// the context tier is skipped and the token-budget tier fires.
	if !strings.Contains(body.Error.Message, "largest provider token budget") {
		t.Fatalf("message = %q, want servability token-budget detail", body.Error.Message)
	}
}

// TestServabilityGateDefaultOnShedsUnservable pins the code default: with
// EIGENINFERENCE_SERVABILITY_GATE unset and SetServabilityGate never called,
// the gate behaves as ON and sheds the unservable request at preflight with the
// servability 429 — matching prod, which has run the gate explicitly enabled.
func TestServabilityGateDefaultOnShedsUnservable(t *testing.T) {
	srv, req := servabilityHarness(t)
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "") // pin "unset" regardless of ambient env

	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want %d; body = %s", w.Code, http.StatusTooManyRequests, w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Fatal("Retry-After header missing on default-on servability 429")
	}
	if !strings.Contains(w.Body.String(), "largest provider token budget") {
		t.Fatalf("body = %q, want the servability token-budget detail (gate must default ON)", w.Body.String())
	}
}

// TestServabilityGateDisabledAdmits pins the explicit-off behaviour
// (EIGENINFERENCE_SERVABILITY_GATE=false): the servability preflight is a no-op,
// so the SAME oversized request + provider instead flows into the normal
// capacity ladder, which rejects it for a DIFFERENT reason (machine busy / "at
// capacity") — never the servability message.
func TestServabilityGateDisabledAdmits(t *testing.T) {
	srv, req := servabilityHarness(t)
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false") // explicit off; SetServabilityGate intentionally NOT called

	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	body := w.Body.String()
	// The defining assertion: the servability gate did NOT produce this response
	// (neither its token-budget nor its context-window variant).
	if strings.Contains(body, "largest provider token budget") || strings.Contains(body, "token context window") {
		t.Fatalf("servability 429 fired with the gate OFF (must be a no-op); body = %s", body)
	}
	// And positively: the request proceeded past preflight into the normal
	// capacity path, which sheds it as a busy/at-capacity 429 instead.
	if w.Code != http.StatusTooManyRequests || !strings.Contains(body, "at capacity") {
		t.Fatalf("gate-off request did not take the capacity path: status=%d body=%s", w.Code, body)
	}
}

// TestServabilityGateTransientFullnessNotShed pins the structural-only
// contract: the SAME ~10,064-token request against a provider whose CEILING
// holds it (20,000) but whose live remainder does not (20,000 − 18,000 used =
// 2,000) must NOT be shed by the servability gate — that fleet is merely busy,
// and queue-before-shed owns the wait. The request instead falls through to
// the capacity ladder (the queue-spill branch; it fast-sheds as a capacity 429
// here only because the harness disables queue-before-shed for determinism).
// Under the pre-fix live-subtract math the gate 429'd this request as
// prompt_too_long before the queue path could ever see it.
func TestServabilityGateTransientFullnessNotShed(t *testing.T) {
	srv, req := servabilityHarnessWithBudget(t, 20_000, 18_000)
	srv.SetServabilityGate(true)

	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	body := w.Body.String()
	// The defining assertion: shedIfUnservable did not produce this response
	// (neither its token-budget nor its context-window variant).
	if strings.Contains(body, "largest provider token budget") || strings.Contains(body, "context window") {
		t.Fatalf("servability gate shed a transiently-full fleet (must be structural-only); body = %s", body)
	}
	// And positively: the request reached the capacity/queue path, whose
	// fast-shed (queue-before-shed disabled) rejects as busy/at-capacity.
	if w.Code != http.StatusTooManyRequests || !strings.Contains(body, "at capacity") {
		t.Fatalf("transiently-full request did not reach the capacity/queue path: status=%d body=%s", w.Code, body)
	}
}

// TestServabilityGate_CalibrationShedsContextOversized (DAR-347) proves the
// per-family prompt-token calibration is wired into the context tier. The prompt
// is sized so the RAW len/4 estimate + max_tokens stays UNDER the model context
// (so an uncalibrated gate would admit it → dispatch → provider 503), while the
// CALIBRATED estimate (gpt-oss ×1.3) crosses the context window and is shed at
// preflight as an uptime-neutral 429. The provider carries a large token budget
// so the token-budget tier cannot fire — isolating the context tier.
func TestServabilityGate_CalibrationShedsContextOversized(t *testing.T) {
	t.Setenv("EIGENINFERENCE_QUEUE_BEFORE_SHED", "false")
	srv, st := testServer(t)
	srv.SetServabilityGate(true)

	const model = "gpt-oss-ctx-test" // contains "gpt-oss" → calibration ×1.3 applies
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})

	// Model registry record supplies modelMaxContext. modelRegistryRecordLocked
	// needs an active entry + a ready, promoted version.
	entry := &store.ModelRegistryEntry{
		ID: model, DisplayName: "ctx", Quantization: "4bit",
		MaxContextLength: 131072, MaxOutputLength: 32768, MinRAMGB: 24, Status: "active",
	}
	files := []store.ModelVersionFile{{Path: "config.json", SizeBytes: 1, SHA256: testHash, Role: "config"}}
	if err := st.SetModelVersion(entry, &store.ModelVersion{
		ModelID: model, Version: "v1", R2Prefix: modelR2Prefix(model, "v1"),
		AggregateSHA256: testHash, TotalSizeBytes: 1, FileCount: 1, Status: "ready",
	}, files); err != nil {
		t.Fatalf("SetModelVersion: %v", err)
	}
	if err := st.PromoteModelVersion(model, "v1"); err != nil {
		t.Fatalf("PromoteModelVersion: %v", err)
	}

	// Resident provider with a LARGE structural token budget so PredictServable's
	// tier-2 (prompt_too_long) cannot fire — the only tier that can shed here is
	// tier-1 (context), and only because of the calibration.
	p := registerBuildsProvider(srv, "ctx-provider", model)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].State = "running"
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 5_000_000
	p.Mu().Unlock()

	// ~440,000 chars → est ~110,000 prompt tokens (len/4). With max_tokens 64:
	//   raw:        110,064          < 131,072  → uncalibrated tier-1 PASSES
	//   calibrated: 110,000×1.3 + 64 = 143,064 > 131,072 → calibrated tier-1 SHEDS
	hugePrompt := strings.Repeat("x", 440000)
	reqBody, err := json.Marshal(map[string]any{
		"model":      model,
		"messages":   []any{map[string]any{"role": "user", "content": hugePrompt}},
		"max_tokens": 64,
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(string(reqBody)))
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (calibrated prompt exceeds context); body=%s", w.Code, w.Body.String())
	}
	if w.Header().Get("Retry-After") == "" {
		t.Error("missing Retry-After on context-oversized 429")
	}
	if !strings.Contains(w.Body.String(), "context window") {
		t.Errorf("body missing context-window detail (want the context_exceeded tier, proving calibration tripped tier-1); body=%s", w.Body.String())
	}
}
