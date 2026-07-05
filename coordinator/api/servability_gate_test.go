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
// serve a request of this size before admitting it. When the gate is ON and the
// request is unservable it returns an uptime-neutral 429 + Retry-After (so
// OpenRouter fails over) instead of admitting it and letting a provider 5xx. When
// the gate is OFF (the default) it is a no-op and the request flows into the
// normal capacity ladder.
//
// The two tests below are a single A/B: identical server + provider + oversized
// request, the ONLY difference being SetServabilityGate(true) vs the default-off.

// servabilityHarness builds the shared fixture: a server with one routable,
// model-resident provider whose single slot advertises a deliberately small
// structural token budget (4096), plus an oversized chat request whose
// (estimated prompt + max_tokens) far exceeds that budget.
//
// The provider setup mirrors the routing tests in consumer_test.go:
// registerBuildsProvider yields a trusted, challenge-fresh, runtime-verified
// provider that passes the same gates real routing applies. The only addition is
// setting the resident slot's ActiveTokenBudgetMax — both PredictServable's
// tier-2 (prompt_too_long) and the capacity path's freeMemoryAdmits read it, so a
// small value makes the oversized request structurally unservable on the (only)
// provider.
//
// queue-before-shed is disabled so the gate-OFF case fast-sheds with an immediate
// capacity 429 instead of spilling the permanently-unservable request into the
// 120s dispatch queue — keeping the test deterministic and fast. It has no
// bearing on the gate-ON case, which returns before that branch is reached.
func servabilityHarness(t *testing.T) (*Server, *http.Request) {
	t.Helper()
	t.Setenv("EIGENINFERENCE_QUEUE_BEFORE_SHED", "false")

	srv, _ := testServer(t)
	const model = "servability-budget-model"
	srv.registry.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 1, MinRAMGB: 24}})

	p := registerBuildsProvider(srv, "servability-small-budget-provider", model)
	p.Mu().Lock()
	// Resident slot ("running" => modelLoaded) carrying a tiny structural token
	// budget: PredictServable uses the reported ActiveTokenBudgetMax for resident
	// slots rather than a cold estimate.
	p.BackendCapacity.Slots[0].State = "running"
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 4096
	p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 0
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

// TestServabilityGateDisabledAdmits pins the gate-OFF (default) behaviour: the
// servability preflight is a no-op, so the SAME oversized request + provider
// instead flows into the normal capacity ladder, which rejects it for a DIFFERENT
// reason (machine busy / "at capacity") — never the servability message.
func TestServabilityGateDisabledAdmits(t *testing.T) {
	srv, req := servabilityHarness(t) // gate OFF: SetServabilityGate intentionally NOT called

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
