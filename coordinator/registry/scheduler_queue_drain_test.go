package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestDrainQueuedRequestsPopulatesDecision(t *testing.T) {
	reg := New(testLogger())
	model := "queue-decision-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 90)
	p.mu.Lock()
	p.BackendCapacity = nil
	p.mu.Unlock()

	req := &QueuedRequest{
		RequestID:  "queued-decision",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:             "queued-decision",
			Model:                 model,
			RequestedMaxTokens:    256,
			EstimatedPromptTokens: 50,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// SetProviderIdle triggers drainQueuedRequestsForModels which fills
	// req.Decision before signaling ResponseCh.
	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil {
			t.Fatal("expected provider, got nil")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for queue dispatch")
	}

	if req.Decision.ProviderID != p.ID {
		t.Fatalf("Decision.ProviderID=%q, want %q", req.Decision.ProviderID, p.ID)
	}
	if req.Decision.CostMs <= 0 {
		t.Fatalf("Decision.CostMs=%f, want > 0", req.Decision.CostMs)
	}
	if req.Decision.CandidateCount != 1 {
		t.Fatalf("Decision.CandidateCount=%d, want 1", req.Decision.CandidateCount)
	}
}

func TestDrainQueuedRequestsForProvider(t *testing.T) {
	reg := New(testLogger())
	model := "attest-drain-model"
	p := makeSchedulerProvider(t, reg, "p1", model, 90)

	// nil provider is a safe no-op (never panics).
	reg.DrainQueuedRequestsForProvider(nil)

	req := &QueuedRequest{
		RequestID:  "queued-attest",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:             "queued-attest",
			Model:                 model,
			RequestedMaxTokens:    256,
			EstimatedPromptTokens: 50,
		},
	}
	if err := reg.Queue().Enqueue(req); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	// Draining by provider (as on a CodeAttested flip) must dispatch the queued
	// request to that provider's model without waiting for a heartbeat.
	reg.DrainQueuedRequestsForProvider(p)

	select {
	case assigned := <-req.ResponseCh:
		if assigned == nil || assigned.ID != p.ID {
			t.Fatalf("expected dispatch to %q, got %+v", p.ID, assigned)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for provider-drain dispatch")
	}
}

func TestDrainQueuedRequestsSkipsUnassignableTargetedRequest(t *testing.T) {
	reg := New(testLogger())
	model := "queue-targeted-model"
	p := makeSchedulerProvider(t, reg, "available-provider", model, 90)
	setSchedulerProviderSerial(p, "AVAILABLE-SERIAL")

	targeted := &QueuedRequest{
		RequestID:  "queued-targeted",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:              "queued-targeted",
			Model:                  model,
			RequestedMaxTokens:     128,
			AllowedProviderSerials: []string{"MISSING-SERIAL"},
		},
	}
	untargeted := &QueuedRequest{
		RequestID:  "queued-untargeted",
		Model:      model,
		ResponseCh: make(chan *Provider, 1),
		Pending: &PendingRequest{
			RequestID:          "queued-untargeted",
			Model:              model,
			RequestedMaxTokens: 128,
		},
	}
	if err := reg.Queue().Enqueue(targeted); err != nil {
		t.Fatalf("enqueue targeted: %v", err)
	}
	if err := reg.Queue().Enqueue(untargeted); err != nil {
		t.Fatalf("enqueue untargeted: %v", err)
	}

	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-untargeted.ResponseCh:
		if assigned == nil {
			t.Fatal("untargeted request got nil provider")
		}
		if assigned.ID != p.ID {
			t.Fatalf("assigned %q, want %q", assigned.ID, p.ID)
		}
	case <-time.After(time.Second):
		t.Fatal("untargeted request was blocked behind unassignable targeted request")
	}

	select {
	case assigned := <-targeted.ResponseCh:
		t.Fatalf("targeted request should remain queued, got provider %#v", assigned)
	default:
	}
	if got := reg.Queue().QueueSize(model); got != 1 {
		t.Fatalf("queue size = %d, want 1 targeted request still queued", got)
	}
}

func TestReserveProviderExWhenNoneAvailable(t *testing.T) {
	reg := New(testLogger())
	model := "missing-model"

	req := &PendingRequest{
		RequestID:          "req-empty",
		Model:              model,
		RequestedMaxTokens: 256,
	}
	provider, decision := reg.ReserveProviderEx(model, req)
	if provider != nil {
		t.Fatalf("expected nil provider, got %q", provider.ID)
	}
	if decision.ProviderID != "" {
		t.Fatalf("decision.ProviderID=%q, want empty", decision.ProviderID)
	}
	if decision.Model != model {
		t.Fatalf("decision.Model=%q, want %q", decision.Model, model)
	}
	if decision.CandidateCount != 0 {
		t.Fatalf("decision.CandidateCount=%d, want 0", decision.CandidateCount)
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

func TestDrainQueuedRequestsRespectsPerSlotCapsAcrossModels(t *testing.T) {
	reg := New(testLogger())
	modelA := "queue-slot-full-a"
	modelB := "queue-slot-open-b"
	p := makeSchedulerProvider(t, reg, "multi-slot", modelA, 100)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelB, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: modelA, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
		{Model: modelB, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
	}
	p.mu.Unlock()

	p.AddPending(&PendingRequest{RequestID: "existing-a", Model: modelA, RequestedMaxTokens: 128})
	queuedA := &QueuedRequest{
		RequestID:  "queued-a",
		Model:      modelA,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-a", Model: modelA, RequestedMaxTokens: 128},
	}
	queuedB := &QueuedRequest{
		RequestID:  "queued-b",
		Model:      modelB,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-b", Model: modelB, RequestedMaxTokens: 128},
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
	default:
		t.Fatal("queued B should drain while model A is at its per-slot cap")
	}
	select {
	case assigned := <-queuedA.ResponseCh:
		t.Fatalf("queued A should remain queued at per-slot cap, got %#v", assigned)
	default:
	}
	if got := reg.Queue().QueueSize(modelA); got != 1 {
		t.Fatalf("model A queue size = %d, want 1", got)
	}
	if got := reg.Queue().QueueSize(modelB); got != 0 {
		t.Fatalf("model B queue size = %d, want 0", got)
	}
}

func TestSetProviderIdleDrainsOnlyFreedModelCapacity(t *testing.T) {
	reg := New(testLogger())
	modelA := "idle-freed-a"
	modelB := "idle-unchanged-b"
	p := makeSchedulerProvider(t, reg, "idle-multi", modelA, 100)
	p.mu.Lock()
	p.Models = append(p.Models, protocol.ModelInfo{ID: modelB, ModelType: "chat", Quantization: "4bit"})
	p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{
		{Model: modelA, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
		{Model: modelB, State: "running", NumRunning: 0, NumWaiting: 0, MaxConcurrency: 1},
	}
	p.mu.Unlock()

	p.AddPending(&PendingRequest{RequestID: "active-a", Model: modelA, RequestedMaxTokens: 128})
	p.AddPending(&PendingRequest{RequestID: "active-b", Model: modelB, RequestedMaxTokens: 128})
	queuedA := &QueuedRequest{
		RequestID:  "queued-a-after-free",
		Model:      modelA,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-a-after-free", Model: modelA, RequestedMaxTokens: 128},
	}
	queuedB := &QueuedRequest{
		RequestID:  "queued-b-still-full",
		Model:      modelB,
		ResponseCh: make(chan *Provider, 1),
		Pending:    &PendingRequest{RequestID: "queued-b-still-full", Model: modelB, RequestedMaxTokens: 128},
	}
	if err := reg.Queue().Enqueue(queuedA); err != nil {
		t.Fatalf("enqueue A: %v", err)
	}
	if err := reg.Queue().Enqueue(queuedB); err != nil {
		t.Fatalf("enqueue B: %v", err)
	}

	p.RemovePending("active-a")
	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-queuedA.ResponseCh:
		if assigned == nil || assigned.ID != p.ID {
			t.Fatalf("queued A assigned %#v, want provider %q", assigned, p.ID)
		}
	default:
		t.Fatal("queued A should drain after model A capacity is freed")
	}
	select {
	case assigned := <-queuedB.ResponseCh:
		t.Fatalf("queued B should remain queued because model B capacity was not freed, got %#v", assigned)
	default:
	}
	if got := reg.Queue().QueueSize(modelA); got != 0 {
		t.Fatalf("model A queue size = %d, want 0", got)
	}
	if got := reg.Queue().QueueSize(modelB); got != 1 {
		t.Fatalf("model B queue size = %d, want 1", got)
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
