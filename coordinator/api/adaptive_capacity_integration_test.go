package api

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
	"nhooyr.io/websocket"
)

func setupAdaptiveCapacityIntegration(t *testing.T) (*httptest.Server, *registry.Registry) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = time.Hour
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

func TestAdaptiveCapacityIntegrationHeartbeatMaxConcurrencyDrivesMultiModelRouting(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	modelA := "adaptive-heartbeat-a"
	modelB := "adaptive-heartbeat-b"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: modelA, ModelType: "chat", Quantization: "4bit"},
		{ID: modelB, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, modelA, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: modelA, State: "running", MaxConcurrency: 1, ActiveTokenBudgetMax: 32_768},
			{Model: modelB, State: "running", MaxConcurrency: 2, ActiveTokenBudgetMax: 32_768},
		},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		return p.MaxConcurrencyForModel(modelA) == 1 && p.MaxConcurrencyForModel(modelB) == 2
	})

	firstA := &registry.PendingRequest{RequestID: "first-a", Model: modelA, EstimatedPromptTokens: 10, RequestedMaxTokens: 128}
	if selected := reg.ReserveProvider(modelA, firstA); selected == nil || selected.ID != p.ID {
		t.Fatalf("first model A request selected %#v, want provider %q", selected, p.ID)
	}

	secondA := &registry.PendingRequest{RequestID: "second-a", Model: modelA, EstimatedPromptTokens: 10, RequestedMaxTokens: 128}
	selectedA, decisionA := reg.ReserveProviderEx(modelA, secondA)
	if selectedA != nil {
		t.Fatalf("second model A request selected %q, want nil at slot cap", selectedA.ID)
	}
	if decisionA.CapacityRejections != 1 {
		t.Fatalf("model A capacity rejections = %d, want 1", decisionA.CapacityRejections)
	}

	firstB := &registry.PendingRequest{RequestID: "first-b", Model: modelB, EstimatedPromptTokens: 10, RequestedMaxTokens: 128}
	if selected := reg.ReserveProvider(modelB, firstB); selected == nil || selected.ID != p.ID {
		t.Fatalf("model B request selected %#v, want provider %q despite model A saturation", selected, p.ID)
	}
}

func TestAdaptiveCapacityIntegrationQueueDrainUsesHeartbeatSlotCaps(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	modelA := "adaptive-queue-a"
	modelB := "adaptive-queue-b"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: modelA, ModelType: "chat", Quantization: "4bit"},
		{ID: modelB, ModelType: "chat", Quantization: "4bit"},
	}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, modelA, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: modelA, State: "running", MaxConcurrency: 1, ActiveTokenBudgetMax: 32_768},
			{Model: modelB, State: "running", MaxConcurrency: 1, ActiveTokenBudgetMax: 32_768},
		},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool { return p.MaxConcurrencyForModel(modelA) == 1 })

	p.AddPending(&registry.PendingRequest{RequestID: "active-a", ProviderID: p.ID, Model: modelA, RequestedMaxTokens: 128})
	queuedA := &registry.QueuedRequest{
		RequestID:  "queued-a",
		Model:      modelA,
		ResponseCh: make(chan *registry.Provider, 1),
		Pending:    &registry.PendingRequest{RequestID: "queued-a", Model: modelA, RequestedMaxTokens: 128},
	}
	queuedB := &registry.QueuedRequest{
		RequestID:  "queued-b",
		Model:      modelB,
		ResponseCh: make(chan *registry.Provider, 1),
		Pending:    &registry.PendingRequest{RequestID: "queued-b", Model: modelB, RequestedMaxTokens: 128},
	}
	if err := reg.Queue().Enqueue(queuedA); err != nil {
		t.Fatalf("enqueue A: %v", err)
	}
	if err := reg.Queue().Enqueue(queuedB); err != nil {
		t.Fatalf("enqueue B: %v", err)
	}

	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-queuedB.ResponseCh:
		if assigned == nil || assigned.ID != p.ID {
			t.Fatalf("queued B assigned %#v, want provider %q", assigned, p.ID)
		}
	case <-time.After(time.Second):
		t.Fatal("queued B should drain while model A is saturated")
	}
	select {
	case assigned := <-queuedA.ResponseCh:
		t.Fatalf("queued A should remain queued at model A slot cap, got %#v", assigned)
	default:
	}

	p.RemovePending("active-a")
	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-queuedA.ResponseCh:
		if assigned == nil || assigned.ID != p.ID {
			t.Fatalf("queued A assigned %#v after freeing capacity, want provider %q", assigned, p.ID)
		}
	case <-time.After(time.Second):
		t.Fatal("queued A should drain after model A capacity is freed")
	}
}

func TestAdaptiveCapacityIntegrationHTTP429WhenTokenBudgetExhausted(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	// Routing v2 W3: with queue-before-shed ON (the default) a token-budget
	// exhausted request is QUEUED rather than fast-429'd (see
	// TestAdaptiveCapacityIntegrationQueueBeforeShedQueuesInsteadOf429). This test
	// pins the legacy fast-shed path that the flag-off behaviour preserves.
	t.Setenv(envQueueBeforeShed, "false")

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

func TestAdaptiveCapacityIntegrationOmittedMaxConcurrencyUsesLegacyFallback(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	model := "adaptive-legacy-fallback"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, testPublicKeyB64())
	defer conn.Close(websocket.StatusNormalClosure, "done")
	p := markOnlyProviderRoutable(t, reg)

	writeAdaptiveHeartbeat(t, ctx, conn, model, &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "running"}},
	})
	waitForAdaptiveCondition(t, time.Second, func() bool {
		return p.MaxConcurrencyForModel(model) == 6
	})

	for i := range 4 {
		p.AddPending(&registry.PendingRequest{RequestID: fmt.Sprintf("legacy-%d", i), ProviderID: p.ID, Model: model, RequestedMaxTokens: 128})
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(model, 10, 128, registry.RequestTraits{})
	if candidates != 1 || rejections != 0 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 1/0 with legacy fallback", candidates, rejections)
	}
}
