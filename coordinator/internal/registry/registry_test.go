package registry

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/dginf/coordinator/internal/attestation"
	"github.com/dginf/coordinator/internal/protocol"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
}

func testRegisterMessage() *protocol.RegisterMessage {
	return &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			ChipFamily:         "M3",
			ChipTier:           "Max",
			MemoryGB:           64,
			MemoryAvailableGB:  60,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
			MemoryBandwidthGBs: 400,
		},
		Models: []protocol.ModelInfo{
			{
				ID:           "mlx-community/Qwen3.5-9B-Instruct-4bit",
				SizeBytes:    5700000000,
				ModelType:    "qwen3",
				Quantization: "4bit",
			},
		},
		Backend: "vllm_mlx",
	}
}

func TestRegisterAndGetProvider(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p := reg.Register("p1", nil, msg)

	if p.ID != "p1" {
		t.Errorf("id = %q, want %q", p.ID, "p1")
	}
	if p.Status != StatusOnline {
		t.Errorf("status = %q, want %q", p.Status, StatusOnline)
	}
	if len(p.Models) != 1 {
		t.Errorf("models = %d, want 1", len(p.Models))
	}

	got := reg.GetProvider("p1")
	if got == nil {
		t.Fatal("GetProvider returned nil")
	}
	if got.ID != "p1" {
		t.Errorf("got id = %q", got.ID)
	}

	if reg.ProviderCount() != 1 {
		t.Errorf("count = %d, want 1", reg.ProviderCount())
	}
}

func TestHeartbeat(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{RequestsServed: 5, TokensGenerated: 1000},
	}

	reg.Heartbeat("p1", hb)

	p := reg.GetProvider("p1")
	if p.Stats.RequestsServed != 5 {
		t.Errorf("requests_served = %d, want 5", p.Stats.RequestsServed)
	}
	if p.Stats.TokensGenerated != 1000 {
		t.Errorf("tokens_generated = %d, want 1000", p.Stats.TokensGenerated)
	}
}

func TestHeartbeatUnknownProvider(t *testing.T) {
	reg := New(testLogger())
	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
	}
	// Should not panic.
	reg.Heartbeat("unknown", hb)
}

func TestDisconnect(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	reg.Disconnect("p1")

	if reg.GetProvider("p1") != nil {
		t.Error("provider should be nil after disconnect")
	}
	if reg.ProviderCount() != 0 {
		t.Errorf("count = %d, want 0", reg.ProviderCount())
	}
}

func TestDisconnectUnknown(t *testing.T) {
	reg := New(testLogger())
	// Should not panic.
	reg.Disconnect("nonexistent")
}

func TestFindProvider(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	p := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p == nil {
		t.Fatal("FindProvider returned nil")
	}
	if p.ID != "p1" {
		t.Errorf("id = %q, want %q", p.ID, "p1")
	}
	if p.Status != StatusServing {
		t.Errorf("status = %q, want %q", p.Status, StatusServing)
	}
}

func TestFindProviderNoMatch(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	p := reg.FindProvider("nonexistent-model")
	if p != nil {
		t.Error("FindProvider should return nil for unknown model")
	}
}

func TestFindProviderSkipsServing(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// First call marks p1 as serving.
	p := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p == nil {
		t.Fatal("first FindProvider returned nil")
	}

	// Second call should return nil since p1 is serving and no other providers.
	p2 := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p2 != nil {
		t.Error("should return nil when only provider is serving")
	}
}

func TestFindProviderRoundRobin(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)
	reg.Register("p2", nil, msg)

	// First call.
	first := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if first == nil {
		t.Fatal("first FindProvider returned nil")
	}
	// Mark it idle so it can be picked again.
	reg.SetProviderIdle(first.ID)

	// Second call.
	second := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if second == nil {
		t.Fatal("second FindProvider returned nil")
	}

	// They should be different providers (round-robin).
	if first.ID == second.ID {
		t.Errorf("expected round-robin, got same provider %q twice", first.ID)
	}
}

func TestSetProviderIdle(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Mark as serving.
	reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	p := reg.GetProvider("p1")
	if p.Status != StatusServing {
		t.Errorf("status = %q, want %q", p.Status, StatusServing)
	}

	reg.SetProviderIdle("p1")
	if p.Status != StatusOnline {
		t.Errorf("status = %q, want %q after idle", p.Status, StatusOnline)
	}
}

func TestListModels(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)
	reg.Register("p2", nil, msg)

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models len = %d, want 1 (deduplicated)", len(models))
	}
	if models[0].ID != "mlx-community/Qwen3.5-9B-Instruct-4bit" {
		t.Errorf("model id = %q", models[0].ID)
	}
	if models[0].Providers != 2 {
		t.Errorf("providers = %d, want 2", models[0].Providers)
	}
	if models[0].AttestedProviders != 0 {
		t.Errorf("attested_providers = %d, want 0 (no attestation)", models[0].AttestedProviders)
	}
}

func TestListModelsWithAttestedProvider(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// Register one attested and one unattested provider
	p1 := reg.Register("p1", nil, msg)
	p1.Attested = true
	p1.AttestationResult = &attestation.VerificationResult{
		Valid:                  true,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	reg.Register("p2", nil, msg)

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models len = %d, want 1", len(models))
	}
	if models[0].AttestedProviders != 1 {
		t.Errorf("attested_providers = %d, want 1", models[0].AttestedProviders)
	}
	if models[0].Attestation == nil {
		t.Fatal("attestation should not be nil")
	}
	if !models[0].Attestation.SecureEnclave {
		t.Error("expected secure_enclave = true")
	}
	if !models[0].Attestation.SIPEnabled {
		t.Error("expected sip_enabled = true")
	}
	if !models[0].Attestation.SecureBoot {
		t.Error("expected secure_boot = true")
	}
}

func TestListModelsEmpty(t *testing.T) {
	reg := New(testLogger())
	models := reg.ListModels()
	if len(models) != 0 {
		t.Errorf("models len = %d, want 0", len(models))
	}
}

func TestEviction(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	// Backdate the heartbeat.
	p.LastHeartbeat = time.Now().Add(-2 * time.Minute)

	// Manually call eviction with a 90-second timeout.
	reg.evictStale(90 * time.Second)

	if reg.GetProvider("p1") != nil {
		t.Error("provider should have been evicted")
	}
	if reg.ProviderCount() != 0 {
		t.Errorf("count = %d, want 0", reg.ProviderCount())
	}
}

func TestEvictionKeepsFreshProviders(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Fresh provider — should not be evicted.
	reg.evictStale(90 * time.Second)

	if reg.GetProvider("p1") == nil {
		t.Error("fresh provider should not be evicted")
	}
}

func TestEvictionLoopStopsOnCancel(t *testing.T) {
	reg := New(testLogger())
	ctx, cancel := context.WithCancel(context.Background())

	reg.StartEvictionLoop(ctx, 100*time.Millisecond)

	// Give the goroutine time to start.
	time.Sleep(50 * time.Millisecond)
	cancel()
	// Give the goroutine time to stop.
	time.Sleep(100 * time.Millisecond)
	// If we get here without hanging, the test passes.
}

func TestTrustLevels(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p := reg.Register("p1", nil, msg)
	if p.TrustLevel != TrustNone {
		t.Errorf("default trust level = %q, want %q", p.TrustLevel, TrustNone)
	}

	// Set self-signed trust
	p.TrustLevel = TrustSelfSigned
	if p.TrustLevel != TrustSelfSigned {
		t.Errorf("trust level = %q, want %q", p.TrustLevel, TrustSelfSigned)
	}

	// Set hardware trust
	p.TrustLevel = TrustHardware
	if p.TrustLevel != TrustHardware {
		t.Errorf("trust level = %q, want %q", p.TrustLevel, TrustHardware)
	}
}

func TestListModelsWithTrustLevel(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustSelfSigned
	p1.Attested = true
	p1.AttestationResult = &attestation.VerificationResult{
		Valid:                  true,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustNone

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models len = %d, want 1", len(models))
	}
	if models[0].TrustLevel != TrustSelfSigned {
		t.Errorf("trust_level = %q, want %q", models[0].TrustLevel, TrustSelfSigned)
	}
}

func TestMarkUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	reg.MarkUntrusted("p1")

	p := reg.GetProvider("p1")
	if p.Status != StatusUntrusted {
		t.Errorf("status = %q, want %q", p.Status, StatusUntrusted)
	}
}

func TestFindProviderSkipsUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Mark untrusted
	reg.MarkUntrusted("p1")

	// Should not find the provider
	p := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p != nil {
		t.Error("FindProvider should skip untrusted providers")
	}
}

func TestListModelsExcludesUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	reg.MarkUntrusted("p1")

	models := reg.ListModels()
	if len(models) != 0 {
		t.Errorf("models len = %d, want 0 (untrusted excluded)", len(models))
	}
}

func TestRecordChallengeSuccess(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	// Record some failures first
	reg.RecordChallengeFailure("p1")
	reg.RecordChallengeFailure("p1")

	// Now record success
	reg.RecordChallengeSuccess("p1")

	if p.FailedChallenges != 0 {
		t.Errorf("failed_challenges = %d, want 0 after success", p.FailedChallenges)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Error("last_challenge_verified should be set")
	}
}

func TestRecordChallengeFailure(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	count := reg.RecordChallengeFailure("p1")
	if count != 1 {
		t.Errorf("failure count = %d, want 1", count)
	}
	if p.FailedChallenges != 1 {
		t.Errorf("failed_challenges = %d, want 1", p.FailedChallenges)
	}

	count = reg.RecordChallengeFailure("p1")
	if count != 2 {
		t.Errorf("failure count = %d, want 2", count)
	}
}

func TestChallengeFailureThreshold(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Record failures up to the threshold
	for i := 0; i < 3; i++ {
		reg.RecordChallengeFailure("p1")
	}

	// The caller (handleChallengeFailure) is responsible for calling MarkUntrusted,
	// not RecordChallengeFailure itself. Let's verify the count is correct.
	p := reg.GetProvider("p1")
	if p.FailedChallenges != 3 {
		t.Errorf("failed_challenges = %d, want 3", p.FailedChallenges)
	}
}

func TestPendingRequests(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	pr := &PendingRequest{
		RequestID: "req-1",
		ChunkCh:   make(chan string, 1),
		CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh:   make(chan protocol.InferenceErrorMessage, 1),
	}
	p.AddPending(pr)

	if p.PendingCount() != 1 {
		t.Errorf("pending count = %d, want 1", p.PendingCount())
	}

	got := p.GetPending("req-1")
	if got == nil {
		t.Fatal("GetPending returned nil")
	}
	if got.RequestID != "req-1" {
		t.Errorf("request_id = %q", got.RequestID)
	}

	removed := p.RemovePending("req-1")
	if removed == nil {
		t.Fatal("RemovePending returned nil")
	}
	if p.PendingCount() != 0 {
		t.Errorf("pending count after remove = %d", p.PendingCount())
	}
}
