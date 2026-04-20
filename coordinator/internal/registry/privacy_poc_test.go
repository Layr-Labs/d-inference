package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/store"
)

// This documents the current downgrade boundary: if the operator lowers the
// global trust floor to none and the provider has fresh challenge/runtime
// state, a provider without attestation becomes routable.
func TestPrivacyPOC_OpenModeProviderBecomesRoutableWhenTrustFloorLowered(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "open-mode-model", SizeBytes: 1000, ModelType: "qwen3", Quantization: "4bit"},
		},
		Backend: "vllm_mlx",
	}

	p := reg.Register("open-mode-provider", nil, msg)
	p.mu.Lock()
	p.TrustLevel = TrustNone
	p.RuntimeVerified = true
	p.LastChallengeVerified = time.Now()
	p.mu.Unlock()

	found := reg.FindProvider("open-mode-model")
	if found == nil {
		t.Fatal("expected open-mode provider to become routable when global trust floor is lowered")
	}
	if found.ID != p.ID {
		t.Fatalf("routed provider = %q, want %q", found.ID, p.ID)
	}
}

// This documents a more subtle trust-restoration boundary: a freshly connected
// provider can regain stored hardware trust and fresh challenge state from the
// persistence layer before any new MDM/ACME re-verification completes.
func TestPrivacyPOC_RestoreProviderStateCanRegrantHardwareTrustImmediately(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustHardware

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "restored-hw-model", SizeBytes: 1000, ModelType: "qwen3", Quantization: "4bit"},
		},
		Backend: "vllm_mlx",
	}

	p := reg.Register("restored-provider", nil, msg)

	// Simulate the freshly verified self-signed path before persisted state is restored.
	p.mu.Lock()
	p.TrustLevel = TrustSelfSigned
	p.RuntimeVerified = true
	p.LastChallengeVerified = time.Now()
	p.mu.Unlock()

	lastVerified := time.Now()
	reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:                    "stored-provider-record",
		TrustLevel:            string(TrustHardware),
		Attested:              true,
		MDAVerified:           true,
		ACMEVerified:          true,
		RuntimeVerified:       true,
		LastChallengeVerified: &lastVerified,
	})

	found := reg.FindProviderWithTrust("restored-hw-model", TrustHardware)
	if found == nil {
		t.Fatal("expected restored provider to become hardware-routable immediately after state restore")
	}
	if found.ID != p.ID {
		t.Fatalf("routed provider = %q, want %q", found.ID, p.ID)
	}
}

// This documents another soft-default boundary: provider registration starts
// with RuntimeVerified=true, so in deployments without a manifest gate the only
// remaining barriers are trust floor and challenge freshness.
func TestPrivacyPOC_RegisterDefaultsRuntimeVerifiedBeforeManifestChecks(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "default-runtime-model", SizeBytes: 1000, ModelType: "qwen3", Quantization: "4bit"},
		},
		Backend: "vllm_mlx",
	}

	p := reg.Register("default-runtime-provider", nil, msg)
	p.mu.Lock()
	runtimeVerified := p.RuntimeVerified
	p.TrustLevel = TrustNone
	p.LastChallengeVerified = time.Now()
	p.mu.Unlock()

	if !runtimeVerified {
		t.Fatal("expected newly registered provider to default to RuntimeVerified=true")
	}

	found := reg.FindProvider("default-runtime-model")
	if found == nil {
		t.Fatal("expected default-runtime provider to become routable with lowered trust floor and fresh challenge")
	}
	if found.ID != p.ID {
		t.Fatalf("routed provider = %q, want %q", found.ID, p.ID)
	}
}
