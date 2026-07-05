package api

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

// chatRequestWithHeaders posts a chat completion and returns status, body, and
// the Retry-After header (adaptiveChatRequest drops headers).
func chatRequestWithHeaders(ctx context.Context, baseURL, model string) (int, string, string, error) {
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":64}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		return 0, "", "", err
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", "", err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data), resp.Header.Get("Retry-After"), nil
}

// TestDedicatedModelShed429NotServiceUnavailable verifies that when a dedicated
// model (gemma-4) is served by the fleet but no DEDICATED box can take the
// request (only a mixed gemma-4+qwen box exists), the coordinator sheds to
// OpenRouter with a transient 429 + Retry-After — NOT a 503. A truly-absent,
// non-dedicated model still returns 503.
func TestDedicatedModelShed429NotServiceUnavailable(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()
	reg.SetDedicatedModels([]string{"gemma-4"})
	// Keep cold-dispatch from spilling to the queue; pin the preflight shed path.
	t.Setenv(envColdDispatch, "false")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	gemma := "gemma-4-26b-test"
	qwen := "qwen-3-test"
	// A single MIXED provider: advertises gemma-4 AND qwen -> not dedicated.
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: gemma, ModelType: "chat", Quantization: "4bit"},
		{ID: qwen, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, gemma, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: gemma, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 32_768},
		},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil
	})

	// Gemma-4 to a mixed-only fleet -> transient 429 + Retry-After (not 503).
	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
	if err != nil {
		t.Fatalf("gemma request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("gemma status = %d, want 429; body = %s", status, body)
	}
	if !strings.Contains(body, "rate_limit_exceeded") {
		t.Fatalf("gemma body = %s, want rate_limit_exceeded", body)
	}
	if retryAfter == "" {
		t.Fatalf("gemma 429 missing Retry-After header")
	}

	// Control: a non-dedicated model absent from the fleet still 503s.
	statusC, bodyC, _, err := chatRequestWithHeaders(ctx, ts.URL, "totally-absent-model")
	if err != nil {
		t.Fatalf("control request: %v", err)
	}
	if statusC != http.StatusServiceUnavailable {
		t.Fatalf("control status = %d, want 503; body = %s", statusC, bodyC)
	}
	if !strings.Contains(bodyC, "model_unavailable") {
		t.Fatalf("control body = %s, want model_unavailable", bodyC)
	}

	// The legacy /v1/completions endpoint (handleGenericInference) must classify
	// the dedicated shed identically — 429, not 503.
	cbody := `{"model":"` + gemma + `","prompt":"hello","stream":true,"max_tokens":64}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/completions", strings.NewReader(cbody))
	if err != nil {
		t.Fatalf("completions request build: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("completions request: %v", err)
	}
	defer resp.Body.Close()
	cdata, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("/v1/completions status = %d, want 429; body = %s", resp.StatusCode, string(cdata))
	}
	if resp.Header.Get("Retry-After") == "" {
		t.Fatalf("/v1/completions 429 missing Retry-After header")
	}
}

// TestDedicatedSaturatedBoxFast429 verifies that when the dedicated box for a
// Gemma 4 request EXISTS but is at capacity, the request is fast-429'd
// immediately instead of sitting in the 120s queue-before-shed window (which is
// left at its default ON) — so OpenRouter fails over within its TTFT SLA.
func TestDedicatedSaturatedBoxFast429(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()
	reg.SetDedicatedModels([]string{"gemma-4"})
	// queue-before-shed left at default (ON): dedicated models must still fast-429.

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	gemma := "gemma-4-26b-test"
	// A single DEDICATED gemma-4 box with its token budget nearly exhausted.
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: gemma, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, gemma, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 gemma,
			State:                 "running",
			MaxConcurrency:        8,
			ActiveTokenBudgetUsed: 950,
			ActiveTokenBudgetMax:  1_000,
		}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil && p.BackendCapacity.Slots[0].ActiveTokenBudgetMax == 1_000
	})

	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
	if err != nil {
		t.Fatalf("request: %v (a hang here means the dedicated request was queued instead of fast-429'd)", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 (dedicated boxes bypass queue-before-shed when saturated); body = %s", status, body)
	}
	if retryAfter == "" {
		t.Fatalf("saturated dedicated 429 missing Retry-After header")
	}
}
