package trust_test

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/api/releases"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestProviderRegistrationBindsProtectedRuntimeClaims(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: registry.Qwen38NAXModelID}})
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: memory.NewMemory(store.Config{AdminKey: "test-key"}), Logger: logger}, production.Config{})
	restoreEmptyChallengeHistory(t, srv)
	metallibHash := strings.Repeat("a", 64)
	srv.releases.SetRuntimeManifest(&releases.RuntimeManifest{
		TemplateHashes: map[string]map[string]bool{"mlx_metallib": {metallibHash: true}},
	})
	publicKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:    protocol.TypeRegister,
		Version: "0.9.9",
		Hardware: protocol.Hardware{
			ChipName:   "Apple M5 Max",
			ChipFamily: "M5",
		},
		Models:    []protocol.ModelInfo{{ID: registry.Qwen38NAXModelID}},
		Backend:   "mlx-swift",
		PublicKey: publicKey,
		Attestation: buildTestAttestationJSONWithFields(
			t,
			publicKey,
			"",
			"",
			time.Now(),
			map[string]interface{}{
				"chipFamily":   "M5",
				"chipName":     "Apple M5 Max",
				"metallibHash": metallibHash,
				"runtimeCapabilities": []string{
					registry.ProviderCapabilityAppleM5,
					registry.ProviderCapabilityMLXNAX,
				},
			},
		),
		RuntimeCapabilities: []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		},
		TemplateHashes: map[string]string{"mlx_metallib": metallibHash},
	}
	provider := reg.Register("signed-runtime", nil, regMsg)
	srv.VerifyProviderAttestation(context.Background(), provider.ID, provider, regMsg)
	runtimeOK, mismatches := srv.releases.VerifyRuntimeHashesForBackend(
		regMsg.Backend, regMsg.TemplateHashes)
	if !runtimeOK {
		t.Fatalf("runtime manifest rejected valid metallib: %v", mismatches)
	}
	provider.Mu().Lock()
	provider.RuntimeVerified = true
	provider.RuntimeManifestChecked = true
	provider.MetallibVerified = true
	provider.TemplateHashes = registry.CloneStringMap(regMsg.TemplateHashes)
	provider.Mu().Unlock()
	if err := reg.ReconcileAttestedRuntimeCapabilities(provider.ID); err != nil {
		t.Fatal(err)
	}
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("capabilities promoted before hardware/code trust: %v",
			provider.RuntimeCapabilities)
	}
	if got := reg.ModelProviderSnapshot()[registry.Qwen38NAXModelID]; got != 0 {
		t.Fatalf("protected model exposed while hardware/code trust pending: %d", got)
	}

	reg.SetTrustLevel(provider.ID, registry.TrustHardware)
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("hardware trust alone promoted capabilities: %v",
			provider.RuntimeCapabilities)
	}
	provider.SetFreshCodeAttested()
	provider.Mu().Lock()
	provider.ChallengeVerifiedSIP = true
	provider.LastChallengeVerified = time.Now()
	provider.Mu().Unlock()
	if len(provider.RuntimeCapabilities) != 2 {
		t.Fatalf("fully verified runtime capabilities = %v",
			provider.RuntimeCapabilities)
	}
	provider.SetCodeAttested(false)
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("code-attestation loss retained capabilities: %v",
			provider.RuntimeCapabilities)
	}
	provider.SetFreshCodeAttested()
	if got := reg.ModelProviderSnapshot()[registry.Qwen38NAXModelID]; got != 1 {
		t.Fatalf("valid signed protected model count = %d, want 1", got)
	}
	reg.SetTrustLevel(provider.ID, registry.TrustSelfSigned)
	if len(provider.RuntimeCapabilities) != 0 {
		t.Fatalf("hardware-trust loss retained capabilities: %v",
			provider.RuntimeCapabilities)
	}
}

func TestProviderRegistrationAttestationFreshness(t *testing.T) {
	cases := []struct {
		name            string
		version         string
		timestampOffset time.Duration
		accepted        bool
	}{
		{
			name:            "missing version rejects stale replay",
			timestampOffset: -10 * time.Minute,
		},
		{
			name:            "release rejects stale replay",
			version:         "0.9.9",
			timestampOffset: -10 * time.Minute,
		},
		{
			name:            "accepts future skew just under boundary",
			version:         "0.9.9",
			timestampOffset: production.RegistrationAttestationMaxFutureSkew - time.Second,
			accepted:        true,
		},
		{
			name:            "accepts future skew at boundary",
			version:         "0.9.9",
			timestampOffset: production.RegistrationAttestationMaxFutureSkew,
			accepted:        true,
		},
		{
			name:            "rejects future skew just over boundary",
			version:         "0.9.9",
			timestampOffset: production.RegistrationAttestationMaxFutureSkew + time.Second,
		},
		{
			name:     "accepts fresh reconnect",
			version:  "0.9.9",
			accepted: true,
		},
		{
			name:     "missing version accepts fresh reconnect",
			accepted: true,
		},
	}

	for index, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				logger := slog.New(slog.NewTextHandler(io.Discard, nil))
				reg := registry.New(logger)
				srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: memory.NewMemory(store.Config{AdminKey: "test-key"}), Logger: logger}, production.Config{})
				restoreEmptyChallengeHistory(t, srv)
				defer srv.Close()
				publicKey := testPublicKeyB64()
				// The bubble freezes time at a whole-second instant while this
				// synchronous verification runs, so the signed fixture keeps exact
				// below/at/one-second-over boundary coverage without aging between
				// construction and CheckTimestamp. Production clocks are untouched.
				timestamp := time.Now().Add(tc.timestampOffset)
				regMsg := &protocol.RegisterMessage{
					Type:      protocol.TypeRegister,
					Version:   tc.version,
					PublicKey: publicKey,
					Attestation: buildTestAttestationJSONWithFields(
						t, publicKey, "", "", timestamp, nil),
				}
				provider := reg.Register(fmt.Sprintf("reconnect-%d", index), nil, regMsg)
				srv.VerifyProviderAttestation(context.Background(), provider.ID, provider, regMsg)

				provider.Mu().Lock()
				defer provider.Mu().Unlock()
				if tc.accepted {
					if provider.Status == registry.StatusUntrusted ||
						provider.AttestationResult == nil ||
						!provider.AttestationResult.Valid {
						t.Fatalf("freshness-compatible registration rejected: status=%s result=%+v",
							provider.Status, provider.AttestationResult)
					}
					if provider.LastChallengeVerified.IsZero() {
						t.Fatal("accepted registration did not initialize periodic challenge freshness")
					}
					return
				}
				if provider.Status != registry.StatusUntrusted ||
					provider.AttestationResult == nil ||
					provider.AttestationResult.Error != "attestation timestamp outside freshness window" {
					t.Fatalf("replayed attestation state = status=%s result=%+v",
						provider.Status, provider.AttestationResult)
				}
				if len(provider.RuntimeCapabilities) != 0 {
					t.Fatalf("replayed attestation retained capabilities: %v",
						provider.RuntimeCapabilities)
				}
			})
		})
	}
}

func TestProviderRegistrationRequiresBinaryHashWhenPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	restoreEmptyChallengeHistory(t, srv)
	srv.releases.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "missing-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             buildTestAttestationJSON(t, pubKey, "", ""),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.VerifyProviderAttestation(context.Background(), "provider-1", p, regMsg)

	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if p.AttestationResult.Valid {
		t.Fatal("attestation should be invalid when binary hash policy is configured and hash is missing")
	}
	if p.AttestationResult.Error != "binary hash missing" {
		t.Fatalf("attestation error = %q, want %q", p.AttestationResult.Error, "binary hash missing")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
	if p.TrustLevel != registry.TrustNone {
		t.Fatalf("provider trust = %q, want %q", p.TrustLevel, registry.TrustNone)
	}
}

func TestProviderRegistrationAcceptsKnownBinaryHash(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	restoreEmptyChallengeHistory(t, srv)
	srv.releases.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "known-binary-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, knownGoodBinaryHashForTest),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.VerifyProviderAttestation(context.Background(), "provider-1", p, regMsg)

	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if !p.AttestationResult.Valid {
		t.Fatalf("attestation should be valid with a known binary hash, got %q", p.AttestationResult.Error)
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status == registry.StatusUntrusted {
		t.Fatal("provider should not be marked untrusted with a known binary hash")
	}
	if p.TrustLevel != registry.TrustSelfSigned {
		t.Fatalf("provider trust = %q, want %q", p.TrustLevel, registry.TrustSelfSigned)
	}
}

func TestProviderRegistrationRejectsInvalidConfiguredBinaryHash(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	restoreEmptyChallengeHistory(t, srv)
	srv.releases.SetKnownBinaryHashes([]string{"not-a-sha256"})
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: exercise the legacy enforcement path

	pubKey := testPublicKeyB64()
	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "invalid-configured-hash-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		PublicKey:               pubKey,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
		Attestation:             createTestAttestationJSONWithBinaryHash(t, pubKey, "not-a-sha256"),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.VerifyProviderAttestation(context.Background(), "provider-1", p, regMsg)

	policyConfigured, knownHashes := srv.releases.BinaryHashPolicySnapshot()
	if !policyConfigured {
		t.Fatal("binary hash policy should remain configured even when configured hashes are invalid")
	}
	if len(knownHashes) != 0 {
		t.Fatalf("known binary hashes = %d, want 0 valid hashes", len(knownHashes))
	}
	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if p.AttestationResult.Valid {
		t.Fatal("attestation should be invalid when configured hash and reported hash are invalid")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
}

// TestProviderRegistrationWithoutAttestationRejectedWhenBinaryHashPolicyConfigured
// verifies that when a binary-hash policy is in force (SetKnownBinaryHashes),
// a Register message with no attestation is marked Untrusted with the
// "attestation missing" error rather than silently accepted.
//
// Ported from master's coordinator/internal/api/provider_test.go (PR #99 regression).
func TestProviderRegistrationWithoutAttestationRejectedWhenBinaryHashPolicyConfigured(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := newTrustFixture(t, production.Dependencies{Registry: reg, Store: st, Logger: logger}, production.Config{})
	restoreEmptyChallengeHistory(t, srv)
	srv.releases.SetKnownBinaryHashes([]string{knownGoodBinaryHashForTest})
	srv.releases.SetBinaryHashEnforcement(true) // v0.6.0: binaryHash gating is off by default; exercise the legacy enforcement path

	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:                  []protocol.ModelInfo{{ID: "no-attestation-policy-model", ModelType: "chat", Quantization: "4bit"}},
		Backend:                 "mlx-swift",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	p := reg.Register("provider-1", nil, regMsg)

	srv.VerifyProviderAttestation(context.Background(), "provider-1", p, regMsg)

	if p.AttestationResult == nil {
		t.Fatal("expected attestation result")
	}
	if p.AttestationResult.Valid {
		t.Fatal("missing attestation should be invalid when binary hash policy is configured")
	}
	if p.AttestationResult.Error != "attestation missing" {
		t.Fatalf("attestation error = %q, want %q", p.AttestationResult.Error, "attestation missing")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.Status != registry.StatusUntrusted {
		t.Fatalf("provider status = %q, want %q", p.Status, registry.StatusUntrusted)
	}
}
