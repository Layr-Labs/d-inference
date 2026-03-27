package registry

import (
	"context"
	"fmt"
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
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware

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

func TestFindProviderSkipsAtMaxConcurrency(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware

	// Fill up the provider to max concurrency by adding pending requests.
	for i := 0; i < MaxConcurrentRequests; i++ {
		p1.AddPending(&PendingRequest{RequestID: fmt.Sprintf("req-%d", i)})
	}

	// FindProvider should return nil since p1 is at max concurrency.
	p := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p != nil {
		t.Error("should return nil when provider is at max concurrency")
	}

	// Remove one pending request — should be routable again.
	p1.RemovePending("req-0")
	p = reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p == nil {
		t.Error("should return provider after freeing a slot")
	}
}

func TestFindProviderScoreBased(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// Register two providers with different benchmark data.
	// p2 has higher decode_tps, so it should be preferred.
	p1 := reg.Register("p1", nil, msg)
	p1.DecodeTPS = 50.0
	p1.TrustLevel = TrustHardware

	p2 := reg.Register("p2", nil, msg)
	p2.DecodeTPS = 100.0
	p2.TrustLevel = TrustHardware

	// First call should pick p2 (higher score).
	first := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if first == nil {
		t.Fatal("first FindProvider returned nil")
	}
	if first.ID != "p2" {
		t.Errorf("expected p2 (higher decode_tps), got %q", first.ID)
	}

	// Mark p2 idle so it can be picked again.
	reg.SetProviderIdle(first.ID)

	// Second call should still pick p2 (higher score, score-based not round-robin).
	second := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if second == nil {
		t.Fatal("second FindProvider returned nil")
	}
	if second.ID != "p2" {
		t.Errorf("expected p2 again (score-based), got %q", second.ID)
	}
}

func TestSetProviderIdle(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware

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
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustHardware

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

	// Register one attested and one unattested provider (both hardware-trusted)
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	p1.Attested = true
	p1.AttestationResult = &attestation.VerificationResult{
		Valid:                  true,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustHardware

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
	p1.TrustLevel = TrustHardware
	p1.Attested = true
	p1.AttestationResult = &attestation.VerificationResult{
		Valid:                  true,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	// self_signed provider should NOT appear in model list
	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustSelfSigned

	models := reg.ListModels()
	if len(models) != 1 {
		t.Fatalf("models len = %d, want 1", len(models))
	}
	if models[0].TrustLevel != TrustHardware {
		t.Errorf("trust_level = %q, want %q", models[0].TrustLevel, TrustHardware)
	}
	if models[0].Providers != 1 {
		t.Errorf("providers = %d, want 1 (only hardware-trusted)", models[0].Providers)
	}
}

func TestListModelsExcludesSelfSigned(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// Only self_signed provider — should NOT appear
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustSelfSigned

	models := reg.ListModels()
	if len(models) != 0 {
		t.Errorf("models len = %d, want 0 (self_signed excluded)", len(models))
	}
}

func TestFindProviderSkipsSelfSigned(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustSelfSigned

	p := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p != nil {
		t.Error("FindProvider should skip self_signed providers")
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

// --- scoring tests ---

func TestScoringHigherDecodeTPS(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.DecodeTPS = 50.0
	p1.TrustLevel = TrustHardware

	p2 := reg.Register("p2", nil, msg)
	p2.DecodeTPS = 200.0
	p2.TrustLevel = TrustHardware

	// p2 should be selected (higher decode_tps).
	selected := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if selected == nil {
		t.Fatal("FindProvider returned nil")
	}
	if selected.ID != "p2" {
		t.Errorf("expected p2 (higher decode_tps), got %q", selected.ID)
	}
}

func TestScoringTrustedPreferred(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// p1 is not hardware-trusted — should be excluded entirely.
	p1 := reg.Register("p1", nil, msg)
	p1.DecodeTPS = 100.0
	p1.TrustLevel = TrustSelfSigned // excluded from routing

	// p2 is hardware-trusted — should be the only candidate.
	p2 := reg.Register("p2", nil, msg)
	p2.DecodeTPS = 100.0
	p2.TrustLevel = TrustHardware

	selected := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if selected == nil {
		t.Fatal("FindProvider returned nil")
	}
	if selected.ID != "p2" {
		t.Errorf("expected p2 (hardware trust), got %q", selected.ID)
	}
}

func TestScoringIdlePreferredOverBusy(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// Both providers have equal decode_tps. p1 already has pending requests.
	p1 := reg.Register("p1", nil, msg)
	p1.DecodeTPS = 100.0
	p1.TrustLevel = TrustHardware

	p2 := reg.Register("p2", nil, msg)
	p2.DecodeTPS = 100.0
	p2.TrustLevel = TrustHardware

	// Give p1 pending requests so it has load.
	p1.AddPending(&PendingRequest{RequestID: "busy-1"})
	p1.AddPending(&PendingRequest{RequestID: "busy-2"})

	// p2 should be selected because it's idle (score is higher with no load).
	selected := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if selected == nil {
		t.Fatal("FindProvider returned nil")
	}
	if selected.ID != "p2" {
		t.Errorf("expected p2 (idle), got %q", selected.ID)
	}
}

func TestScoringWarmModelPreferred(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	// Both have same decode_tps and trust, but p2 has the model warm.
	p1 := reg.Register("p1", nil, msg)
	p1.DecodeTPS = 100.0
	p1.TrustLevel = TrustHardware

	p2 := reg.Register("p2", nil, msg)
	p2.DecodeTPS = 100.0
	p2.TrustLevel = TrustHardware
	p2.WarmModels = []string{"mlx-community/Qwen3.5-9B-Instruct-4bit"}

	selected := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if selected == nil {
		t.Fatal("FindProvider returned nil")
	}
	if selected.ID != "p2" {
		t.Errorf("expected p2 (warm model), got %q", selected.ID)
	}
}

func TestScoreProviderFunction(t *testing.T) {
	p := &Provider{
		DecodeTPS:  100.0,
		TrustLevel: TrustHardware,
		Status:     StatusOnline,
		Reputation: NewReputation(),
	}

	score := ScoreProvider(p, "test-model")
	if score <= 0 {
		t.Errorf("score = %f, should be positive", score)
	}

	// Provider with pending requests should have a lower score (load penalty).
	p.Status = StatusServing
	p.mu.Lock()
	p.pendingReqs = map[string]*PendingRequest{"r1": {RequestID: "r1"}}
	p.mu.Unlock()
	busyScore := ScoreProvider(p, "test-model")
	if busyScore >= score {
		t.Errorf("busy score (%f) should be less than idle score (%f)", busyScore, score)
	}
	if busyScore <= 0 {
		t.Errorf("busy score = %f, should still be positive (has concurrency headroom)", busyScore)
	}
}

func TestTrustMultiplierValues(t *testing.T) {
	if TrustMultiplier(TrustHardware) != 1.0 {
		t.Errorf("hardware multiplier = %f, want 1.0", TrustMultiplier(TrustHardware))
	}
	if TrustMultiplier(TrustSelfSigned) != 0.8 {
		t.Errorf("self_signed multiplier = %f, want 0.8", TrustMultiplier(TrustSelfSigned))
	}
	if TrustMultiplier(TrustNone) != 0.5 {
		t.Errorf("none multiplier = %f, want 0.5", TrustMultiplier(TrustNone))
	}
}

func TestRecordJobSuccessUpdatesReputation(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	reg.RecordJobSuccess("p1", 500*time.Millisecond)
	reg.RecordJobSuccess("p1", 500*time.Millisecond)

	if p.Reputation.SuccessfulJobs != 2 {
		t.Errorf("successful_jobs = %d, want 2", p.Reputation.SuccessfulJobs)
	}
	if p.Reputation.TotalJobs != 2 {
		t.Errorf("total_jobs = %d, want 2", p.Reputation.TotalJobs)
	}
}

func TestRecordJobFailureUpdatesReputation(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)

	reg.RecordJobFailure("p1")

	if p.Reputation.FailedJobs != 1 {
		t.Errorf("failed_jobs = %d, want 1", p.Reputation.FailedJobs)
	}
	if p.Reputation.TotalJobs != 1 {
		t.Errorf("total_jobs = %d, want 1", p.Reputation.TotalJobs)
	}
}

func TestBenchmarkFieldsInRegistration(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	msg.PrefillTPS = 500.0
	msg.DecodeTPS = 100.0

	p := reg.Register("p1", nil, msg)
	if p.PrefillTPS != 500.0 {
		t.Errorf("prefill_tps = %f, want 500.0", p.PrefillTPS)
	}
	if p.DecodeTPS != 100.0 {
		t.Errorf("decode_tps = %f, want 100.0", p.DecodeTPS)
	}
}

func TestHeartbeatUpdatesWarmModels(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	model := "mlx-community/Qwen3.5-9B-Instruct-4bit"
	hb := &protocol.HeartbeatMessage{
		Type:        protocol.TypeHeartbeat,
		Status:      "serving",
		ActiveModel: &model,
		Stats:       protocol.HeartbeatStats{},
		WarmModels:  []string{"mlx-community/Qwen3.5-9B-Instruct-4bit"},
	}

	reg.Heartbeat("p1", hb)

	p := reg.GetProvider("p1")
	if len(p.WarmModels) != 1 {
		t.Errorf("warm_models len = %d, want 1", len(p.WarmModels))
	}
	if p.CurrentModel != model {
		t.Errorf("current_model = %q, want %q", p.CurrentModel, model)
	}
}

func TestSetProviderIdleDrainsQueue(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p := reg.Register("p1", nil, msg)
	p.TrustLevel = TrustHardware

	// Mark provider as serving.
	reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")

	// Queue a request.
	qr := &QueuedRequest{
		RequestID:  "req-queued",
		Model:      "mlx-community/Qwen3.5-9B-Instruct-4bit",
		ResponseCh: make(chan *Provider, 1),
	}
	reg.Queue().Enqueue(qr)

	// Set provider idle — should drain queue and assign.
	reg.SetProviderIdle(p.ID)

	// The provider should have been assigned from the queue.
	select {
	case assigned := <-qr.ResponseCh:
		if assigned == nil {
			t.Fatal("expected non-nil provider from queue")
		}
		if assigned.ID != "p1" {
			t.Errorf("assigned provider = %q, want p1", assigned.ID)
		}
	case <-time.After(1 * time.Second):
		t.Error("timed out waiting for queue assignment")
	}
}

func TestScoringWithHighMemoryPressure(t *testing.T) {
	healthy := &Provider{
		DecodeTPS:  100.0,
		TrustLevel: TrustHardware,
		Status:     StatusOnline,
		Reputation: NewReputation(),
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1,
			CPUUsage:       0.1,
			ThermalState:   "nominal",
		},
	}
	pressured := &Provider{
		DecodeTPS:  100.0,
		TrustLevel: TrustHardware,
		Status:     StatusOnline,
		Reputation: NewReputation(),
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.9,
			CPUUsage:       0.1,
			ThermalState:   "nominal",
		},
	}

	healthyScore := ScoreProvider(healthy, "test-model")
	pressuredScore := ScoreProvider(pressured, "test-model")

	if pressuredScore >= healthyScore {
		t.Errorf("pressured score (%f) should be less than healthy score (%f)", pressuredScore, healthyScore)
	}
}

func TestScoringWithThermalThrottling(t *testing.T) {
	p := &Provider{
		DecodeTPS:  100.0,
		TrustLevel: TrustHardware,
		Status:     StatusOnline,
		Reputation: NewReputation(),
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.1,
			CPUUsage:       0.1,
			ThermalState:   "critical",
		},
	}

	score := ScoreProvider(p, "test-model")
	if score != 0 {
		t.Errorf("critical thermal score = %f, want 0", score)
	}
}

func TestFindProviderPrefersHealthy(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.DecodeTPS = 100.0
	p1.TrustLevel = TrustHardware
	p1.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.85,
		CPUUsage:       0.7,
		ThermalState:   "serious",
	}

	p2 := reg.Register("p2", nil, msg)
	p2.DecodeTPS = 100.0
	p2.TrustLevel = TrustHardware
	p2.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.05,
		ThermalState:   "nominal",
	}

	selected := reg.FindProvider("mlx-community/Qwen3.5-9B-Instruct-4bit")
	if selected == nil {
		t.Fatal("FindProvider returned nil")
	}
	if selected.ID != "p2" {
		t.Errorf("expected p2 (healthy), got %q", selected.ID)
	}
}

func TestHeartbeatUpdatesSystemMetrics(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	hb := &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{},
		SystemMetrics: protocol.SystemMetrics{
			MemoryPressure: 0.55,
			CPUUsage:       0.22,
			ThermalState:   "fair",
		},
	}
	reg.Heartbeat("p1", hb)

	p := reg.GetProvider("p1")
	if p.SystemMetrics.MemoryPressure != 0.55 {
		t.Errorf("memory_pressure = %f, want 0.55", p.SystemMetrics.MemoryPressure)
	}
	if p.SystemMetrics.ThermalState != "fair" {
		t.Errorf("thermal_state = %q, want fair", p.SystemMetrics.ThermalState)
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
