package attestation

import (
	"bytes"
	"testing"
)

func TestProcessEvidenceCanonicalV1Golden(t *testing.T) {
	truth := true
	in := ProcessEvidenceCanonicalInput{
		CoordinatorNonce: "nonce-v1", CoordinatorTimestamp: "2026-08-30T12:00:00Z",
		CoordinatorSessionID: "session-123", ChallengeGeneration: "generation-abc",
		EvidenceExpiresAt: "2026-08-30T12:10:00Z",
		SEPublicKey:       "se-public", SerialNumber: "SERIAL-1",
		ProcessPublicKey: "process-public", BinaryHash: "binary-hash",
		ProviderVersion: "0.8.15", ProviderPlatform: "macos-arm64",
		ProviderBackend: "mlx-swift", RuntimeHash: "runtime-hash",
		MetallibHash: "metallib-hash", SIPEnabled: &truth,
		SecureBootEnabled: &truth,
	}
	got, err := BuildProcessEvidenceCanonicalV1(in)
	if err != nil {
		t.Fatal(err)
	}
	expected := []byte(`{"binary_hash":"binary-hash","challenge_generation":"generation-abc","coordinator_nonce":"nonce-v1","coordinator_session_id":"session-123","coordinator_timestamp":"2026-08-30T12:00:00Z","domain":"darkbloom.process_evidence","evidence_expires_at":"2026-08-30T12:10:00Z","metallib_hash":"metallib-hash","process_public_key":"process-public","provider_backend":"mlx-swift","provider_platform":"macos-arm64","provider_version":"0.8.15","runtime_hash":"runtime-hash","se_public_key":"se-public","secure_boot_enabled":true,"serial_number":"SERIAL-1","sip_enabled":true,"version":"process_evidence_v1"}`)
	if !bytes.Equal(got, expected) {
		t.Fatalf("canonical mismatch\n got: %s\nwant: %s", got, expected)
	}
}

func TestProcessEvidenceCanonicalV1NilAndFalseAreDistinct(t *testing.T) {
	base := ProcessEvidenceCanonicalInput{}
	omitted, err := BuildProcessEvidenceCanonicalV1(base)
	if err != nil {
		t.Fatal(err)
	}
	f := false
	base.SIPEnabled = &f
	explicitFalse, err := BuildProcessEvidenceCanonicalV1(base)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(omitted, explicitFalse) || bytes.Contains(omitted, []byte("sip_enabled")) ||
		!bytes.Contains(explicitFalse, []byte(`"sip_enabled":false`)) {
		t.Fatalf("nil/false omission contract drifted: omitted=%s false=%s", omitted, explicitFalse)
	}
}

func TestProcessEvidenceCanonicalV1MutationMatrix(t *testing.T) {
	truth := true
	base := ProcessEvidenceCanonicalInput{
		CoordinatorNonce: "n", CoordinatorTimestamp: "t", CoordinatorSessionID: "s",
		ChallengeGeneration: "g", EvidenceExpiresAt: "e", SEPublicKey: "se",
		SerialNumber: "serial", ProcessPublicKey: "pk", BinaryHash: "bin",
		ProviderVersion: "v", ProviderPlatform: "platform", ProviderBackend: "backend",
		RuntimeHash: "runtime", MetallibHash: "metal", SIPEnabled: &truth,
		SecureBootEnabled: &truth,
	}
	golden, err := BuildProcessEvidenceCanonicalV1(base)
	if err != nil {
		t.Fatal(err)
	}
	mutations := map[string]func(*ProcessEvidenceCanonicalInput){
		"process_key": func(v *ProcessEvidenceCanonicalInput) { v.ProcessPublicKey += "x" },
		"se":          func(v *ProcessEvidenceCanonicalInput) { v.SEPublicKey += "x" },
		"serial":      func(v *ProcessEvidenceCanonicalInput) { v.SerialNumber += "x" },
		"nonce":       func(v *ProcessEvidenceCanonicalInput) { v.CoordinatorNonce += "x" },
		"session":     func(v *ProcessEvidenceCanonicalInput) { v.CoordinatorSessionID += "x" },
		"generation":  func(v *ProcessEvidenceCanonicalInput) { v.ChallengeGeneration += "x" },
		"expiry":      func(v *ProcessEvidenceCanonicalInput) { v.EvidenceExpiresAt += "x" },
		"binary":      func(v *ProcessEvidenceCanonicalInput) { v.BinaryHash += "x" },
		"version":     func(v *ProcessEvidenceCanonicalInput) { v.ProviderVersion += "x" },
		"backend":     func(v *ProcessEvidenceCanonicalInput) { v.ProviderBackend += "x" },
		"runtime":     func(v *ProcessEvidenceCanonicalInput) { v.RuntimeHash += "x" },
		"metallib":    func(v *ProcessEvidenceCanonicalInput) { v.MetallibHash += "x" },
		"sip":         func(v *ProcessEvidenceCanonicalInput) { f := false; v.SIPEnabled = &f },
		"secure_boot": func(v *ProcessEvidenceCanonicalInput) { f := false; v.SecureBootEnabled = &f },
	}
	for name, mutate := range mutations {
		t.Run(name, func(t *testing.T) {
			candidate := base
			mutate(&candidate)
			got, err := BuildProcessEvidenceCanonicalV1(candidate)
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Equal(got, golden) {
				t.Fatalf("mutation did not change canonical bytes: %s", got)
			}
		})
	}
}
