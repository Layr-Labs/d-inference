package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestMaxConcurrencyDefault verifies that providers without BackendCapacity
// fall back to DefaultMaxConcurrent (4).
func TestMaxConcurrencyDefault(t *testing.T) {
	p := &Provider{
		pendingReqs: make(map[string]*PendingRequest),
	}
	if got := p.MaxConcurrency(); got != DefaultMaxConcurrent {
		t.Errorf("MaxConcurrency() = %d, want %d (default)", got, DefaultMaxConcurrent)
	}
}

// TestMaxConcurrencyWithCapacity verifies hardware-based dynamic concurrency.
func TestMaxConcurrencyWithCapacity(t *testing.T) {
	cases := []struct {
		memGB    float64
		expected int
	}{
		// Phase 2 tier values (lowered from 4/8/16/24/32). See
		// maxConcurrency() in registry.go for the rationale.
		{16, 2},
		{24, 2},
		{36, 4},
		{48, 4},
		{64, 6},
		{96, 6},
		{128, 8},
		{192, 12},
		{256, 12},
	}

	for _, tc := range cases {
		p := &Provider{
			pendingReqs: make(map[string]*PendingRequest),
			BackendCapacity: &protocol.BackendCapacity{
				TotalMemoryGB: tc.memGB,
			},
		}
		got := p.MaxConcurrency()
		if got != tc.expected {
			t.Errorf("MaxConcurrency() with %.0f GB = %d, want %d", tc.memGB, got, tc.expected)
		}
	}
}

// TestFindProviderDynamicConcurrency verifies that with dynamic concurrency,
// a provider with 5 pending requests on a 96 GB box is still eligible
// (Phase 2 cap for 96 GB = 6).
func TestFindProviderDynamicConcurrency(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	p.DecodeTPS = 100.0
	// 96 GB → cap=6 under Phase 2.
	p.mu.Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 96,
	}
	p.mu.Unlock()

	// 5 pending is below the new cap of 6.
	for i := range 5 {
		p.AddPending(&PendingRequest{RequestID: fmt.Sprintf("req-%d", i)})
	}

	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Error("FindProvider should return provider with 5/6 capacity used (Phase 2 cap)")
	}
}

// TestHeartbeatBackendCapacity verifies that BackendCapacity from heartbeats
// is stored on the Provider struct.
func TestHeartbeatBackendCapacity(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	cap := &protocol.BackendCapacity{
		Slots: []protocol.BackendSlotCapacity{
			{
				Model:              "mlx-community/Qwen3.5-9B-Instruct-4bit",
				State:              "running",
				NumRunning:         3,
				NumWaiting:         1,
				ActiveTokens:       5000,
				MaxTokensPotential: 12000,
			},
		},
		GPUMemoryActiveGB: 45.2,
		GPUMemoryPeakGB:   52.1,
		GPUMemoryCacheGB:  8.3,
		TotalMemoryGB:     64,
	}

	hb := &protocol.HeartbeatMessage{
		Type:            protocol.TypeHeartbeat,
		Status:          "serving",
		Stats:           protocol.HeartbeatStats{},
		BackendCapacity: cap,
	}
	reg.Heartbeat("p1", hb)

	p := reg.GetProvider("p1")
	p.mu.Lock()
	defer p.mu.Unlock()

	if p.BackendCapacity == nil {
		t.Fatal("BackendCapacity should be set after heartbeat")
	}
	if len(p.BackendCapacity.Slots) != 1 {
		t.Fatalf("expected 1 slot, got %d", len(p.BackendCapacity.Slots))
	}
	if p.BackendCapacity.Slots[0].NumRunning != 3 {
		t.Errorf("num_running = %d, want 3", p.BackendCapacity.Slots[0].NumRunning)
	}
	if p.BackendCapacity.GPUMemoryActiveGB != 45.2 {
		t.Errorf("gpu_memory_active_gb = %f, want 45.2", p.BackendCapacity.GPUMemoryActiveGB)
	}
	if p.BackendCapacity.TotalMemoryGB != 64 {
		t.Errorf("total_memory_gb = %f, want 64", p.BackendCapacity.TotalMemoryGB)
	}
}

// TestBackwardCompatNoCapacity verifies that heartbeats WITHOUT BackendCapacity
// (simulating old providers) work correctly with default limits.
func TestBackwardCompatNoCapacity(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	p.DecodeTPS = 100.0

	// Send heartbeat without BackendCapacity (old provider).
	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{},
	}
	reg.Heartbeat("p1", hb)

	// BackendCapacity should remain nil.
	if p.BackendCapacity != nil {
		t.Error("BackendCapacity should be nil for old providers")
	}

	// MaxConcurrency should return the default.
	if p.MaxConcurrency() != DefaultMaxConcurrent {
		t.Errorf("MaxConcurrency() = %d, want %d (default)", p.MaxConcurrency(), DefaultMaxConcurrent)
	}

	// Provider should be routable with default limits.
	found := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if found == nil {
		t.Error("old provider without BackendCapacity should still be routable")
	}
}

func TestHeartbeatClearsStaleBackendCapacity(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.mu.Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model: "mlx-community/Qwen3.5-9B-Instruct-4bit",
			State: "crashed",
		}},
	}
	p.mu.Unlock()

	reg.Heartbeat("p1", &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{},
	})

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.BackendCapacity != nil {
		t.Fatalf("BackendCapacity=%+v, want nil after omitted heartbeat capacity", p.BackendCapacity)
	}
}

// TestSetProviderIdleDynamicCap verifies that SetProviderIdle drains queued
// requests using dynamic concurrency limits. A provider with max=8 and
// pending=5 should still try to drain after completing a request.
func TestSetProviderIdleDynamicCap(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	p.DecodeTPS = 100.0

	// 96 GB → cap=6 under Phase 2.
	p.mu.Lock()
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 96}
	p.mu.Unlock()

	// 5 pending (under cap of 6).
	for i := range 5 {
		p.AddPending(&PendingRequest{RequestID: fmt.Sprintf("req-%d", i)})
	}

	// Queue a request
	qr := &QueuedRequest{
		RequestID:  "req-queued",
		Model:      "mlx-community/Qwen3.5-9B-Instruct-4bit",
		ResponseCh: make(chan *Provider, 1),
	}
	reg.Queue().Enqueue(qr)

	// Complete one pending → 4/6, queue should drain.
	p.RemovePending("req-0")

	reg.SetProviderIdle(p.ID)

	select {
	case assigned := <-qr.ResponseCh:
		if assigned == nil {
			t.Fatal("expected non-nil provider from queue drain")
		}
		if assigned.ID != "p1" {
			t.Errorf("assigned provider = %q, want p1", assigned.ID)
		}
	case <-time.After(1 * time.Second):
		t.Error("timed out waiting for queue drain — dynamic cap may not be working")
	}
}

// TestFindProviderPrefersCrashedLast verifies that when the only provider
// has a crashed slot for the requested model, it is still returned (with
// low score) rather than returning nil.
func TestFindProviderPrefersCrashedLast(t *testing.T) {
	reg := New(testLogger())
	model := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	msg := testRegisterMessage()

	// Register two providers: one crashed, one hot.
	crashed := reg.Register("crashed-provider", nil, msg)
	crashed.TrustLevel = TrustHardware
	crashed.LastChallengeVerified = time.Now()
	crashed.ChallengeVerifiedSIP = true
	crashed.DecodeTPS = 100.0
	crashed.RuntimeVerified = true
	crashed.mu.Lock()
	crashed.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "crashed"},
		},
	}
	crashed.mu.Unlock()

	hot := reg.Register("hot-provider", nil, msg)
	hot.TrustLevel = TrustHardware
	hot.LastChallengeVerified = time.Now()
	hot.ChallengeVerifiedSIP = true
	hot.DecodeTPS = 100.0
	hot.RuntimeVerified = true
	hot.mu.Lock()
	hot.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "running"},
		},
	}
	hot.mu.Unlock()

	// FindProvider should strongly prefer the hot provider.
	found := findRoutableProvider(reg, model)
	if found == nil {
		t.Fatal("FindProvider returned nil when providers are available")
	}
	if found.ID != "hot-provider" {
		t.Errorf("expected hot-provider, got %q", found.ID)
	}
}
