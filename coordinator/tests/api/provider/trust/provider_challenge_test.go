package trust_test

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func restoreEmptyChallengeHistory(t *testing.T, s *trustFixture) {
	t.Helper()
	s.hooks.RestoreProviderState = func(ctx context.Context, p *registry.Provider, serial, key string, _ ...string) error {
		previous, err := s.store.GetProviderForRestore(ctx, serial, key, []string{p.ID})
		if previous != nil {
			t.Fatal("challenge fixture unexpectedly has persisted provider history")
		}
		if err == nil {
			p.CompleteProviderStateRestore()
		}
		return err
	}
}

func TestChallengeResponseRequiresBinaryHashWhenPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	srv.releases.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	restoreEmptyChallengeHistory(t, srv)
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "missing-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)
	srv.VerifyProviderAttestation(context.Background(), "provider-1", p, regMsg)
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true
	challengeTimestamp := "2026-04-24T12:00:00Z"

	srv.verifyChallengeResponse("provider-1", p, &challengeProofFixture{
		nonce:     "nonce-1",
		timestamp: challengeTimestamp,
	}, withTestStatusSignature("nonce-1", challengeTimestamp, pubKey, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         testChallengeSignature("nonce-1", challengeTimestamp, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
	}))

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.FailedChallenges != 1 {
		t.Fatalf("failed challenges = %d, want 1", p.FailedChallenges)
	}
}
func TestChallengeResponseRejectsHashChangedFromRegistrationAttestation(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	otherKnownHash := strings.Repeat("f", 64)
	srv.releases.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest, otherKnownHash})
	restoreEmptyChallengeHistory(t, srv)
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "changed-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)
	srv.VerifyProviderAttestation(context.Background(), "provider-1", p, regMsg)
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true
	challengeTimestamp := "2026-04-24T12:00:00Z"

	srv.verifyChallengeResponse("provider-1", p, &challengeProofFixture{
		nonce:     "nonce-1",
		timestamp: challengeTimestamp,
	}, withTestStatusSignature("nonce-1", challengeTimestamp, pubKey, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         testChallengeSignature("nonce-1", challengeTimestamp, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
		BinaryHash:        otherKnownHash,
	}))

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.FailedChallenges != 1 {
		t.Fatalf("failed challenges = %d, want 1", p.FailedChallenges)
	}
}
func TestChallengeResponseAcceptsKnownBinaryHash(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	srv.releases.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	restoreEmptyChallengeHistory(t, srv)
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "known-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)
	srv.VerifyProviderAttestation(context.Background(), "provider-1", p, regMsg)
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true
	challengeTimestamp := "2026-04-24T12:00:00Z"

	srv.verifyChallengeResponse("provider-1", p, &challengeProofFixture{
		nonce:     "nonce-1",
		timestamp: challengeTimestamp,
	}, withTestStatusSignature("nonce-1", challengeTimestamp, pubKey, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         testChallengeSignature("nonce-1", challengeTimestamp, pubKey),
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
		BinaryHash:        knownGoodBinaryHashForTest,
	}))

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status == registry.StatusUntrusted {
		t.Fatal("provider should not be marked untrusted with a known binary hash")
	}
	if p.FailedChallenges != 0 {
		t.Fatalf("failed challenges = %d, want 0", p.FailedChallenges)
	}
	if p.LastChallengeVerified.IsZero() {
		t.Fatal("provider should record challenge success with a known binary hash")
	}
}
func TestChallengeResponseRejectsUnsignedBinaryHashWhenPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	srv.releases.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	p := reg.Register("provider-1", nil, &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "unsigned-challenge-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	})
	sipEnabled := true
	secureBootEnabled := true
	rdmaDisabled := true

	srv.verifyChallengeResponse("provider-1", p, &challengeProofFixture{
		nonce:     "nonce-1",
		timestamp: "2026-04-24T12:00:00Z",
	}, &protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             "nonce-1",
		Signature:         "dGVzdHNpZ25hdHVyZQ==",
		PublicKey:         pubKey,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
		RDMADisabled:      &rdmaDisabled,
		BinaryHash:        knownGoodBinaryHashForTest,
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.FailedChallenges != 1 {
		t.Fatalf("failed challenges = %d, want 1", p.FailedChallenges)
	}
	if !p.LastChallengeVerified.IsZero() {
		t.Fatal("provider should not record challenge success for an unsigned binary hash")
	}
}

// Issue #239: hitting the failure threshold via missed-challenge timeouts marks
// the provider untrusted but *recoverable* (the challenge loop keeps probing it).
func TestHandleChallengeFailureThresholdTransientIsRecoverable(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})

	p := reg.Register("p1", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	for range registry.MaxFailedChallenges {
		srv.handleChallengeFailure("p1", "timeout")
	}

	if p.Status != registry.StatusUntrusted {
		t.Fatalf("status = %q, want %q after %d timeouts", p.Status, registry.StatusUntrusted, registry.MaxFailedChallenges)
	}
	if p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = true, want false (timeout-threshold deroute must be recoverable)")
	}
	if reg.OnlineCount() != 0 {
		t.Errorf("OnlineCount = %d, want 0", reg.OnlineCount())
	}
}

// handleChallengeFailure returns the running consecutive-failure count, which
// drives the force-reconnect escalation in handleTransientChallengeFailure.
// A provider whose outbound path is wedged heartbeats forever (never evicted)
// while failing every challenge; the count is what lets the coordinator cycle
// the connection. handleTransientChallengeFailure must also tolerate a nil conn.
func TestHandleChallengeFailureReturnsConsecutiveCountAndNilConnSafe(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})

	reg.Register("p1", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	for i := 1; i <= production.MaxConsecutiveChallengeTimeoutsBeforeReconnect; i++ {
		got := srv.handleChallengeFailure("p1", "timeout")
		if got != i {
			t.Fatalf("handleChallengeFailure call %d returned %d, want %d", i, got, i)
		}
	}

	// A nil conn (e.g. provider already torn down) must not panic even though
	// the count is past the force-reconnect threshold.
	srv.handleTransientChallengeFailure(nil, "p1", "timeout")

	if got := reg.GetProvider("p1"); got == nil || got.Status != registry.StatusUntrusted {
		t.Fatalf("provider should be untrusted after repeated timeouts")
	}
}

// Issue #239: a non-transient reason at the threshold is a hard deroute — the
// challenge loop stops and it cannot self-recover.
func TestHandleChallengeFailureThresholdSecurityIsHard(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})

	p := reg.Register("p1", nil, &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift",
	})

	for range registry.MaxFailedChallenges {
		srv.handleChallengeFailure("p1", "nonce mismatch")
	}

	if p.Status != registry.StatusUntrusted {
		t.Fatalf("status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if !p.ChallengeShouldStop() {
		t.Error("ChallengeShouldStop = false, want true (security-threshold deroute must be hard)")
	}
}
