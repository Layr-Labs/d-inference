package inference

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

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

func setupAdaptiveCapacityIntegration(t *testing.T) (*httptest.Server, *registry.Registry) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	testComposition(srv).SetChallengeInterval(time.Hour)
	ts := httptest.NewServer(srv.Handler())
	return ts, reg
}

func markOnlyProviderRoutable(t *testing.T, reg *registry.Registry) *registry.Provider {
	t.Helper()
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("provider count = %d, want 1", len(ids))
	}
	reg.SetTrustLevel(ids[0], registry.TrustHardware)
	reg.RecordChallengeSuccess(ids[0])
	p := reg.GetProvider(ids[0])
	if p == nil {
		t.Fatalf("provider %q not found", ids[0])
	}
	p.Mu().Lock()
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.Mu().Unlock()
	return p
}

func writeAdaptiveHeartbeat(t *testing.T, ctx context.Context, conn *websocket.Conn, activeModel string, capacity *protocol.BackendCapacity) {
	t.Helper()
	msg := protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "serving",
		Stats:           protocol.HeartbeatStats{},
		WarmModels:      []string{activeModel},
		SystemMetrics:   protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"},
		BackendCapacity: capacity,
	}
	if activeModel != "" {
		msg.ActiveModel = &activeModel
	}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal heartbeat: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}
}

func waitForAdaptiveCondition(t *testing.T, timeout time.Duration, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition not met before timeout")
}

func adaptiveChatRequest(ctx context.Context, baseURL, model string, maxTokens int) (int, string, error) {
	body := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":%d}`, model, maxTokens)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/v1/chat/completions", strings.NewReader(body))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("Authorization", "Bearer test-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data), nil
}

func TestAdaptiveCapacityIntegrationHTTP429WhenTokenBudgetExhausted(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	// Routing v2 W3: with queue-before-shed ON (the default) a token-budget
	// exhausted request is QUEUED rather than fast-429'd (see
	// TestAdaptiveCapacityIntegrationQueueBeforeShedQueuesInsteadOf429). This test
	// pins the legacy fast-shed path that the flag-off behaviour preserves.
	t.Setenv(envQueueBeforeShed, "false")
	// The servability gate (default-on) sheds this known-insufficient budget at
	// preflight with its own 429 before the capacity ladder runs; disable it so
	// this test keeps pinning the capacity fast-shed path (still reachable in
	// prod whenever any eligible provider's budget is unknown).
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	model := "adaptive-budget-http"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
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

	status, body, err := adaptiveChatRequest(ctx, ts.URL, model, 256)
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	if status != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429, body = %s", status, body)
	}
	if !strings.Contains(body, "at capacity") {
		t.Fatalf("body = %s, want capacity error", body)
	}
}

// Routing v2 W3 queue-before-shed: with the flag ON (default), a request that
// the preflight would have 429'd `machine_busy` (all providers at capacity)
// instead enters the dispatch+queue path so a freeing slot can serve it within
// the queue window. We assert the request lands in the queue rather than getting
// an immediate 429.
func TestAdaptiveCapacityIntegrationQueueBeforeShedQueuesInsteadOf429(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	// Ensure the default-on behaviour even if the ambient env disables it.
	t.Setenv(envQueueBeforeShed, "true")
	// Keep cold-dispatch from kicking model swaps in this single-warm-provider
	// scenario — irrelevant here and keeps the test focused on queueing.
	t.Setenv(envColdDispatch, "false")
	// The servability gate (default-on) would shed this known-insufficient
	// budget at preflight before the queue-before-shed branch runs; disable it
	// so this test keeps pinning the queueing path (still reachable in prod
	// whenever any eligible provider's budget is unknown).
	t.Setenv("EIGENINFERENCE_SERVABILITY_GATE", "false")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	model := "adaptive-queue-before-shed"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
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

	// Fire a request whose token budget cannot be admitted right now. It must
	// QUEUE (not return an immediate 429).
	reqCtx, reqCancel := context.WithCancel(ctx)
	defer reqCancel()
	done := make(chan int, 1)
	go func() {
		status, _, _ := adaptiveChatRequest(reqCtx, ts.URL, model, 256)
		done <- status
	}()

	// Within a short window the capacity-rejected request should be sitting in
	// the queue rather than having been shed.
	waitForAdaptiveCondition(t, 3*time.Second, func() bool {
		depth, _ := reg.Queue().QueueStats(model)
		return depth >= 1
	})

	// It must not have already returned a fast 429.
	select {
	case status := <-done:
		t.Fatalf("request returned status %d while it should still be queued (queue-before-shed)", status)
	default:
	}

	// Cancel the queued request and confirm it unwinds cleanly.
	reqCancel()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("queued request did not return after cancellation")
	}
}
