package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
)

func makeSchedulerProvider(t *testing.T, reg *Registry, id, model string, decodeTPS float64) *Provider {
	t.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = decodeTPS
	p := reg.Register(id, nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{
				Model:              model,
				State:              "running",
				NumRunning:         0,
				NumWaiting:         0,
				ActiveTokens:       0,
				MaxTokensPotential: 0,
			},
		},
	}
	p.mu.Unlock()
	return p
}

func TestReserveProviderSkipsSelfSigned(t *testing.T) {
	reg := New(testLogger())
	model := "scheduler-model"
	hw := makeSchedulerProvider(t, reg, "hardware", model, 80)
	self := makeSchedulerProvider(t, reg, "self", model, 200)

	self.mu.Lock()
	self.TrustLevel = TrustSelfSigned
	self.mu.Unlock()

	req := &PendingRequest{
		RequestID:          "req-1",
		Model:              model,
		RequestedMaxTokens: 128,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil")
	}
	if selected.ID != hw.ID {
		t.Fatalf("selected %q, want %q", selected.ID, hw.ID)
	}
}

func TestReserveProviderBalancesAcrossHotSlots(t *testing.T) {
	reg := New(testLogger())
	model := "balanced-model"
	p1 := makeSchedulerProvider(t, reg, "p1", model, 120)
	p2 := makeSchedulerProvider(t, reg, "p2", model, 110)

	req1 := &PendingRequest{RequestID: "req-1", Model: model, RequestedMaxTokens: 256}
	first := reg.ReserveProvider(model, req1)
	if first == nil {
		t.Fatal("first reservation returned nil")
	}

	req2 := &PendingRequest{RequestID: "req-2", Model: model, RequestedMaxTokens: 256}
	second := reg.ReserveProvider(model, req2)
	if second == nil {
		t.Fatal("second reservation returned nil")
	}
	if first.ID == second.ID {
		t.Fatalf("expected second reservation to use a different provider, both went to %q", first.ID)
	}

	// Cleanup so later queue-drain logic isn't affected by sticky pending state.
	first.RemovePending(req1.RequestID)
	reg.SetProviderIdle(first.ID)
	second.RemovePending(req2.RequestID)
	reg.SetProviderIdle(second.ID)

	// Keep the variables live for readability in failure output.
	_ = p1
	_ = p2
}

func TestReserveProviderUsesColdSlotWhenHotBacklogIsHuge(t *testing.T) {
	reg := New(testLogger())
	model := "cold-start-model"
	hot := makeSchedulerProvider(t, reg, "hot", model, 40)
	cold := makeSchedulerProvider(t, reg, "cold", model, 40)

	hot.mu.Lock()
	hot.BackendCapacity.Slots[0].NumRunning = 1
	hot.BackendCapacity.Slots[0].NumWaiting = 2
	hot.BackendCapacity.Slots[0].MaxTokensPotential = 24_000
	hot.mu.Unlock()

	cold.mu.Lock()
	cold.BackendCapacity.Slots[0].State = "idle_shutdown"
	cold.mu.Unlock()

	req := &PendingRequest{
		RequestID:             "req-cold",
		Model:                 model,
		EstimatedPromptTokens: 2_000,
		RequestedMaxTokens:    512,
	}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil")
	}
	if selected.ID != cold.ID {
		t.Fatalf("selected %q, want cold slot %q", selected.ID, cold.ID)
	}
}

func TestReserveProviderSkipsReloadingAndCrashedSlots(t *testing.T) {
	reg := New(testLogger())
	model := "slot-state-model"
	reloading := makeSchedulerProvider(t, reg, "reloading", model, 80)
	crashed := makeSchedulerProvider(t, reg, "crashed", model, 80)
	running := makeSchedulerProvider(t, reg, "running", model, 70)

	reloading.mu.Lock()
	reloading.BackendCapacity.Slots[0].State = "reloading"
	reloading.mu.Unlock()

	crashed.mu.Lock()
	crashed.BackendCapacity.Slots[0].State = "crashed"
	crashed.mu.Unlock()

	req := &PendingRequest{RequestID: "req-state", Model: model, RequestedMaxTokens: 256}
	selected := reg.ReserveProvider(model, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil")
	}
	if selected.ID != running.ID {
		t.Fatalf("selected %q, want running provider %q", selected.ID, running.ID)
	}

	// If only crashed or reloading slots remain, routing should reject.
	selected.RemovePending(req.RequestID)
	reg.SetProviderIdle(selected.ID)
	running.mu.Lock()
	running.BackendCapacity.Slots[0].State = "crashed"
	running.mu.Unlock()

	req2 := &PendingRequest{RequestID: "req-none", Model: model, RequestedMaxTokens: 256}
	if got := reg.ReserveProvider(model, req2); got != nil {
		t.Fatalf("expected no reservation, got %q", got.ID)
	}
}

func TestSetProviderIdleKeepsUntrustedSticky(t *testing.T) {
	reg := New(testLogger())
	model := "sticky-untrusted-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 80)
	p.AddPending(&PendingRequest{RequestID: "req-1", Model: model, RequestedMaxTokens: 128})

	reg.MarkUntrusted(p.ID)
	p.RemovePending("req-1")
	reg.SetProviderIdle(p.ID)

	p.mu.Lock()
	status := p.Status
	p.mu.Unlock()
	if status != StatusUntrusted {
		t.Fatalf("status = %q, want %q", status, StatusUntrusted)
	}
}

func TestDrainQueuedRequestsUsesAllAvailableCapacity(t *testing.T) {
	reg := New(testLogger())
	model := "queue-fill-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 90)
	p.mu.Lock()
	p.BackendCapacity = nil // use default max concurrency (4) for deterministic headroom
	p.mu.Unlock()

	queued := make([]*QueuedRequest, 0, 3)
	for i := range 3 {
		req := &QueuedRequest{
			RequestID:  "queued-" + string(rune('a'+i)),
			Model:      model,
			ResponseCh: make(chan *Provider, 1),
			Pending: &PendingRequest{
				RequestID:          "queued-" + string(rune('a'+i)),
				Model:              model,
				RequestedMaxTokens: 128,
			},
		}
		if err := reg.Queue().Enqueue(req); err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
		queued = append(queued, req)
	}

	reg.SetProviderIdle(p.ID)

	for i, req := range queued {
		select {
		case assigned := <-req.ResponseCh:
			if assigned == nil {
				t.Fatalf("queued request %d received nil provider", i)
			}
			if assigned.ID != p.ID {
				t.Fatalf("queued request %d assigned %q, want %q", i, assigned.ID, p.ID)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for queued request %d", i)
		}
	}

	if got := p.PendingCount(); got != 3 {
		t.Fatalf("pending count = %d, want 3", got)
	}
}

func TestReserveProviderUsesModelSpecificSlotState(t *testing.T) {
	reg := New(testLogger())
	modelA := "model-a"
	modelB := "model-b"
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{
		{ID: modelA, ModelType: "chat", Quantization: "4bit"},
		{ID: modelB, ModelType: "chat", Quantization: "4bit"},
	}
	msg.DecodeTPS = 100
	p := reg.Register("multi", nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: modelA, State: "running", NumRunning: 0, NumWaiting: 0},
			{Model: modelB, State: "crashed", NumRunning: 0, NumWaiting: 0},
		},
	}
	p.mu.Unlock()

	req := &PendingRequest{RequestID: "req-a", Model: modelA, RequestedMaxTokens: 128}
	selected := reg.ReserveProvider(modelA, req)
	if selected == nil {
		t.Fatal("ReserveProvider returned nil for healthy model slot")
	}
	if selected.ID != p.ID {
		t.Fatalf("selected %q, want %q", selected.ID, p.ID)
	}
}

func TestHeartbeatDrainsQueueAfterSlotRecovery(t *testing.T) {
	reg := New(testLogger())
	model := "recovery-model"
	p := makeSchedulerProvider(t, reg, "recover", model, 90)

	p.mu.Lock()
	p.BackendCapacity.Slots[0].State = "crashed"
	p.mu.Unlock()

	req := &QueuedRequest{
		RequestID:  "queued-recovery",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-recovery",
			Model:              model,
			RequestedMaxTokens: 128,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{},
		BackendCapacity: &protocol.BackendCapacity{
			TotalMemoryGB: 64,
			Slots: []protocol.BackendSlotCapacity{
				{Model: model, State: "running", NumRunning: 0, NumWaiting: 0},
			},
		},
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1,
			CPUUsage:       0.1,
			ThermalState:   "nominal",
		},
	}
	reg.Heartbeat(p.ID, hb)

	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil {
			t.Fatal("queued request received nil provider after recovery")
		}
		if assigned.ID != p.ID {
			t.Fatalf("assigned %q, want %q", assigned.ID, p.ID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for recovered slot assignment")
	}
}
