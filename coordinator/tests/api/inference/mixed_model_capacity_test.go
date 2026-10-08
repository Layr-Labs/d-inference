package inference_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
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
	return inferenceRequestWithHeaders(ctx, baseURL+"/v1/chat/completions", body)
}

func inferenceRequestWithHeaders(ctx context.Context, url, body string) (int, string, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(body))
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
	data, err := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data), resp.Header.Get("Retry-After"), err
}

func TestMixedModelProviderServesChatAndCompletions(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	gemma := "gemma-4-26b-test"
	qwen := "qwen-3-test"
	pubKey := testPublicKeyB64()
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: gemma, ModelType: "chat", Quantization: "4bit"},
		{ID: qwen, ModelType: "chat", Quantization: "4bit"},
	}, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, gemma, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: gemma, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 32_768},
			{Model: qwen, State: "running", MaxConcurrency: 8, ActiveTokenBudgetMax: 32_768},
		},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		return p.BackendCapacity != nil && len(p.BackendCapacity.Slots) == 2
	})
	go serveCapacityTestProvider(t, ctx, conn, pubKey)

	for _, model := range []string{gemma, qwen} {
		for _, endpoint := range []struct {
			path, input string
		}{
			{"/v1/chat/completions", `"messages":[{"role":"user","content":"hello"}]`},
			{"/v1/completions", `"prompt":"hello"`},
		} {
			t.Run(model+endpoint.path, func(t *testing.T) {
				payload := `{"model":"` + model + `",` + endpoint.input + `,"stream":true,"max_tokens":64}`
				status, body, retryAfter, err := inferenceRequestWithHeaders(ctx, ts.URL+endpoint.path, payload)
				if err != nil {
					t.Fatal(err)
				}
				if status != http.StatusOK || !strings.Contains(body, "capacity-served") {
					t.Fatalf("mixed-provider response = %d %s, want streamed 200", status, body)
				}
				if retryAfter != "" {
					t.Fatalf("successful response has Retry-After = %q", retryAfter)
				}
			})
		}
	}
}

// A reconnecting fleet is transient capacity exhaustion for every model and
// both inference entry points, not a 503 or a family-specific rejection.
func TestNoEligibleProviderReturnsRetryable429(t *testing.T) {
	ts, _ := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()
	t.Setenv(envColdDispatch, "false")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, model := range []string{"gemma-4-26b-test", "reconnecting-model"} {
		for _, endpoint := range []struct {
			path, input string
		}{
			{"/v1/chat/completions", `"messages":[{"role":"user","content":"hello"}]`},
			{"/v1/completions", `"prompt":"hello"`},
		} {
			t.Run(model+endpoint.path, func(t *testing.T) {
				payload := `{"model":"` + model + `",` + endpoint.input + `,"stream":true,"max_tokens":64}`
				status, body, retryAfter, err := inferenceRequestWithHeaders(ctx, ts.URL+endpoint.path, payload)
				if err != nil {
					t.Fatal(err)
				}
				if status != http.StatusTooManyRequests || !strings.Contains(body, "rate_limit_exceeded") || !strings.Contains(body, "no provider for model") {
					t.Fatalf("no-provider response = %d %s, want generic retryable 429", status, body)
				}
				if seconds, err := strconv.Atoi(retryAfter); err != nil || seconds <= 0 {
					t.Fatalf("Retry-After = %q, want positive seconds", retryAfter)
				}
			})
		}
	}
}

// setupSaturatedMixedProvider boots a coordinator with a mixed-model provider
// whose Gemma token budget is nearly exhausted, so a chat request hits
// the preflight capacity-rejection branch. The servability gate is disabled
// (it would shed the known-insufficient budget before the capacity ladder) and
// cold-dispatch is off to keep the tests pinned on the queue path.
func setupSaturatedMixedProvider(t *testing.T, ctx context.Context) (ts *httptest.Server, reg *registry.Registry, conn *websocket.Conn, pubKey, gemma string) {
	t.Helper()
	ts, reg = setupAdaptiveCapacityIntegration(t)
	t.Cleanup(ts.Close)
	t.Setenv(envQueueBeforeShed, "true")
	t.Setenv(envColdDispatch, "false")
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	gemma = "gemma-4-26b-test"
	pubKey = testPublicKeyB64()
	conn = connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: gemma, ModelType: "chat", Quantization: "4bit"},
		{ID: "qwen-3-test", ModelType: "chat", Quantization: "4bit"},
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

func serveCapacityTestProvider(t *testing.T, ctx context.Context, conn *websocket.Conn, pubKey string) {
	// Routability is pinned by the fixture; a fallback attestation response
	// would invalidate it. Read past challenges and serve only inference.
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if json.Unmarshal(data, &envelope) != nil || envelope.Type != protocol.TypeInferenceRequest {
			continue
		}
		var req protocol.InferenceRequestMessage
		if err := json.Unmarshal(data, &req); err != nil {
			t.Errorf("decode inference request: %v", err)
			return
		}
		sse := `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"capacity-served"},"text":"capacity-served"}]}` + "\n\n"
		writeEncryptedTestChunk(t, ctx, conn, req, pubKey, sse)
		complete, _ := json.Marshal(protocol.InferenceCompleteMessage{
			Type:      protocol.TypeInferenceComplete,
			RequestID: req.RequestID,
			Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
		})
		if conn.Write(ctx, websocket.MessageText, complete) != nil {
			return
		}
	}
}

// Saturation still queues ordinary mixed-model requests until a heartbeat
// exposes free capacity, then drains and completes them end-to-end.
func TestMixedModelSaturationQueuesAndDrains(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ts, reg, conn, pubKey, gemma := setupSaturatedMixedProvider(t, ctx)
	defer conn.Close(websocket.StatusNormalClosure, "done")

	go serveCapacityTestProvider(t, ctx, conn, pubKey)

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

	// The capacity-rejected request must land in the queue.
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		depth, _ := reg.Queue().QueueStats(gemma)
		return depth >= 1
	})
	select {
	case res := <-done:
		t.Fatalf("request returned %d early while it should be queued; body = %s", res.status, res.body)
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
			t.Fatalf("drained request status = %d, want 200; body = %s", res.status, res.body)
		}
		if !strings.Contains(res.body, "capacity-served") {
			t.Fatalf("drained response body = %s, want streamed provider content", res.body)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("queued request did not drain after the provider freed capacity")
	}
}

// A single-slot queue already holding a mixed-model request still rejects the
// next request immediately with 429 and Retry-After.
func TestMixedModelQueueFullReturns429(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ts, reg, conn, _, gemma := setupSaturatedMixedProvider(t, ctx)
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

// A queued mixed-model request that exceeds maxWait still resolves to a
// retryable 429 instead of hanging.
func TestMixedModelQueueTimeoutReturns429(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	ts, reg, conn, _, gemma := setupSaturatedMixedProvider(t, ctx)
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
