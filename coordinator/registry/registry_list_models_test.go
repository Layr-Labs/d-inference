package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestListModels(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	p1.LastChallengeVerified = time.Now()
	p1.ChallengeVerifiedSIP = true
	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustHardware
	p2.LastChallengeVerified = time.Now()
	p2.ChallengeVerifiedSIP = true

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
	p1.LastChallengeVerified = time.Now()
	p1.ChallengeVerifiedSIP = true
	p1.Attested = true
	p1.AttestationResult = &attestation.VerificationResult{
		Valid:                  true,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	p2 := reg.Register("p2", nil, msg)
	p2.TrustLevel = TrustHardware
	p2.LastChallengeVerified = time.Now()
	p2.ChallengeVerifiedSIP = true

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

func TestListModelsWithTrustLevel(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustHardware
	p1.LastChallengeVerified = time.Now()
	p1.ChallengeVerifiedSIP = true
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

func TestModelTypeIncludesUntrusted(t *testing.T) {
	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone

	msg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: testRegisterMessage().Hardware,
		Models: []protocol.ModelInfo{
			{ID: "model-a", SizeBytes: 1000, ModelType: "text", Quantization: "4bit"},
			{ID: "model-b", SizeBytes: 2000, ModelType: "image", Quantization: "8bit"},
		},
		Backend: "vllm_mlx",
	}
	p := reg.Register("p1", nil, msg)

	if got := reg.ModelType("model-a"); got != "text" {
		t.Errorf("ModelType(model-a) = %q, want %q", got, "text")
	}
	if got := reg.ModelType("model-b"); got != "image" {
		t.Errorf("ModelType(model-b) = %q, want %q", got, "image")
	}

	reg.MarkUntrusted(p.ID)

	if got := reg.ModelType("model-a"); got != "text" {
		t.Errorf("ModelType(model-a) after untrusted = %q, want %q", got, "text")
	}
	if got := reg.ModelType("model-b"); got != "image" {
		t.Errorf("ModelType(model-b) after untrusted = %q, want %q", got, "image")
	}
	if got := reg.ModelType("nonexistent"); got != "unknown" {
		t.Errorf("ModelType(nonexistent) = %q, want %q", got, "unknown")
	}
}
