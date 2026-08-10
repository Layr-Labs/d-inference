package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
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
// OpenRouter with a transient 429 + Retry-After — NOT a 503. A model with no
// currently connected provider is also transient capacity: this is the exact
// post-coordinator-restart window while the in-memory fleet registry rebuilds.
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

	// Control/regression: a non-dedicated model with no connected provider also
	// sheds as 429. Returning 503 here caused the OpenRouter uptime collapse
	// during the provider-reconnect minute after a coordinator deployment.
	statusC, bodyC, retryAfterC, err := chatRequestWithHeaders(ctx, ts.URL, "reconnecting-model")
	if err != nil {
		t.Fatalf("control request: %v", err)
	}
	if statusC != http.StatusTooManyRequests {
		t.Fatalf("control status = %d, want 429; body = %s", statusC, bodyC)
	}
	if !strings.Contains(bodyC, "rate_limit_exceeded") {
		t.Fatalf("control body = %s, want rate_limit_exceeded", bodyC)
	}
	if retryAfterC == "" {
		t.Fatal("control 429 missing Retry-After header")
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

// setupSaturatedDedicatedGemma boots a coordinator with a single DEDICATED
// gemma-4 box whose token budget is nearly exhausted, so a chat request hits
// the preflight capacity-rejection branch. The servability gate is disabled
// (it would shed the known-insufficient budget before the capacity ladder) and
// cold-dispatch is off to keep the tests pinned on the queue path.
func setupSaturatedDedicatedGemma(t *testing.T, ctx context.Context) (ts *httptest.Server, reg *registry.Registry, conn *websocket.Conn, pubKey, gemma string) {
	t.Helper()
	ts, reg = setupAdaptiveCapacityIntegration(t)
	t.Cleanup(ts.Close)
	reg.SetDedicatedModels([]string{"gemma-4"})
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	gemma = "gemma-4-26b-test"
	pubKey = testPublicKeyB64()
	conn = connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: gemma, ModelType: "chat", Quantization: "4bit"},
	}, pubKey)
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
		return p.BackendCapacity != nil && p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed == 950
	})
	return ts, reg, conn, pubKey, gemma
}

// TestDedicatedSaturatedBoxQueuesAndDrains verifies the new dedicated-pool
// queueing behavior: when the dedicated box for a Gemma 4 request EXISTS but is
// at capacity, the request QUEUES (no fast 429), drains when the box frees
// capacity, and completes end-to-end. Replaces the retired fast-429 bypass
// (f28e89a9) that shed 283k/week uptime-visible machine_busy 429s to OpenRouter
// while the queue sat idle.
func TestDedicatedSaturatedBoxQueuesAndDrains(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ts, reg, conn, pubKey, gemma := setupSaturatedDedicatedGemma(t, ctx)
	defer conn.Close(websocket.StatusNormalClosure, "done")

	// Serve inference requests but IGNORE attestation challenges: routability is
	// pinned via markOnlyProviderRoutable, and answering the buffered initial
	// challenge with the fallback test signature would deroute the provider.
	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var envlp struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(data, &envlp) != nil || envlp.Type != protocol.TypeInferenceRequest {
				continue
			}
			var inferReq protocol.InferenceRequestMessage
			json.Unmarshal(data, &inferReq)
			sseData := `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"dedicated-drained"}}]}` + "\n\n"
			writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey, sseData)
			complete := protocol.InferenceCompleteMessage{
				Type:      protocol.TypeInferenceComplete,
				RequestID: inferReq.RequestID,
				Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
			}
			completeData, _ := json.Marshal(complete)
			if conn.Write(ctx, websocket.MessageText, completeData) != nil {
				return
			}
		}
	}()

	type result struct {
		status int
		body   string
	}
	done := make(chan result, 1)
	go func() {
		status, body, _, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
		if err != nil {
			done <- result{0, err.Error()}
			return
		}
		done <- result{status, body}
	}()

	// The capacity-rejected dedicated request must land in the queue.
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		depth, _ := reg.Queue().QueueStats(gemma)
		return depth >= 1
	})
	select {
	case res := <-done:
		t.Fatalf("dedicated request returned %d early while it should be queued; body = %s", res.status, res.body)
	default:
	}

	// Free the box: the heartbeat drain must assign the queued request and the
	// provider loop serves it to completion.
	writeAdaptiveHeartbeat(t, ctx, conn, gemma, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                gemma,
			State:                "running",
			MaxConcurrency:       8,
			ActiveTokenBudgetMax: 32_768,
		}},
	})

	select {
	case res := <-done:
		if res.status != http.StatusOK {
			t.Fatalf("drained dedicated request status = %d, want 200; body = %s", res.status, res.body)
		}
		if !strings.Contains(res.body, "dedicated-drained") {
			t.Fatalf("drained response body = %s, want streamed provider content", res.body)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("queued dedicated request did not drain after the provider freed capacity")
	}
}

// TestDedicatedQueueFull429Preserved verifies the queue_full backstop survives
// the dedicated queueing change: with a single-slot queue already holding a
// dedicated request, the next request still gets an immediate 429 +
// Retry-After.
func TestDedicatedQueueFull429Preserved(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ts, reg, conn, _, gemma := setupSaturatedDedicatedGemma(t, ctx)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	reg.SetQueue(registry.NewRequestQueue(1, 30*time.Second))

	firstCtx, firstCancel := context.WithCancel(ctx)
	defer firstCancel()
	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		chatRequestWithHeaders(firstCtx, ts.URL, gemma)
	}()
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		depth, _ := reg.Queue().QueueStats(gemma)
		return depth >= 1
	})

	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
	if err != nil {
		t.Fatalf("second request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("queue-full status = %d, want 429; body = %s", status, body)
	}
	if !strings.Contains(body, "queue is full") {
		t.Fatalf("queue-full body = %s, want queue-is-full error", body)
	}
	if retryAfter == "" {
		t.Fatal("queue-full 429 missing Retry-After header")
	}

	firstCancel()
	select {
	case <-firstDone:
	case <-time.After(3 * time.Second):
		t.Fatal("queued request did not unwind after cancellation")
	}
}

// TestDedicatedQueueTimeout429Preserved verifies the queue_timeout backstop:
// a queued dedicated request whose wait exceeds maxWait still resolves to a
// 429 + Retry-After instead of hanging.
func TestDedicatedQueueTimeout429Preserved(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ts, reg, conn, _, gemma := setupSaturatedDedicatedGemma(t, ctx)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	reg.SetQueue(registry.NewRequestQueue(5, 400*time.Millisecond))

	status, body, retryAfter, err := chatRequestWithHeaders(ctx, ts.URL, gemma)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("queue-timeout status = %d, want 429; body = %s", status, body)
	}
	if !strings.Contains(body, "queue timeout") {
		t.Fatalf("queue-timeout body = %s, want queue-timeout error", body)
	}
	if retryAfter == "" {
		t.Fatal("queue-timeout 429 missing Retry-After header")
	}
}
