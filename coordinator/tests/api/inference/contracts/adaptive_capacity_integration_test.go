package inference_test

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

func setupAdaptiveCapacityIntegration(t *testing.T) (*httptest.Server, *registry.Registry) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetChallengeInterval(time.Hour)
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

func TestAdaptiveCapacityIntegrationHeartbeatMaxConcurrencyDrivesMultiModelRouting(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	modelA := "adaptive-heartbeat-a"
	modelB := "adaptive-heartbeat-b"
	conn := testkit.ConnectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: modelA, ModelType: "chat", Quantization: "4bit"},
		{ID: modelB, ModelType: "chat", Quantization: "4bit"},
	}, testkit.PublicKeyB64())
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
	conn := testkit.ConnectProvider(t, ctx, ts.URL, []protocol.ModelInfo{
		{ID: modelA, ModelType: "chat", Quantization: "4bit"},
		{ID: modelB, ModelType: "chat", Quantization: "4bit"},
	}, testkit.PublicKeyB64())
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

// A running slot that reports no max_concurrency uses the default ceiling.
func TestAdaptiveCapacityIntegrationOmittedMaxConcurrencyUsesDefault(t *testing.T) {
	ts, reg := setupAdaptiveCapacityIntegration(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	model := "adaptive-default-ceiling"
	conn := testkit.ConnectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}, testkit.PublicKeyB64())
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
		p.AddPending(&registry.PendingRequest{RequestID: fmt.Sprintf("default-%d", i), ProviderID: p.ID, Model: model, RequestedMaxTokens: 128})
	}
	candidates, rejections, _ := reg.QuickCapacityCheck(model, 10, 128, registry.RequestTraits{})
	if candidates != 1 || rejections != 0 {
		t.Fatalf("QuickCapacityCheck candidates=%d rejections=%d, want 1/0 under the default ceiling", candidates, rejections)
	}
}
