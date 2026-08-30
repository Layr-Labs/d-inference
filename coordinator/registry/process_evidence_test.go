package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func certifiedProvider(now time.Time) (*Provider, ApplicationEvidence) {
	p := &Provider{
		ID: "session-1", PublicKey: "process-key", APNsDeviceToken: "apns",
		Version: "0.8.15", Backend: BackendMLXSwift, Status: StatusOnline,
		ProcessEvidenceVersion: protocol.ProcessEvidenceV1,
		RuntimeVerified:        true, RuntimeManifestChecked: true, MetallibVerified: true,
		AttestationResult: &attestation.VerificationResult{
			Valid: true, PublicKey: "se-key", SerialNumber: "SERIAL",
		},
		applicationProofSettled: make(chan struct{}),
	}
	certificate := CertifiedProcessEvidence{
		Version: protocol.ProcessEvidenceV1, SEPublicKey: "se-key", Serial: "SERIAL",
		ProcessPublicKey: "process-key", BinaryHash: "binary",
		ProviderVersion: "0.8.15", Platform: "macos-arm64", Backend: BackendMLXSwift,
		RuntimeHash: "runtime", MetallibHash: "metal", CoordinatorSessionID: "session-1",
		ChallengeGeneration: "generation", ExpiresAt: now.Add(time.Minute),
		PolicyGeneration: 7, VerifiedAt: now,
	}
	return p, ApplicationEvidence{
		SEPublicKey: "se-key", Serial: "SERIAL", ProcessPublicKey: "process-key",
		APNsToken: "apns", BinaryHash: "binary", Version: "0.8.15",
		Platform: "macos-arm64", Backend: BackendMLXSwift,
		RuntimeHash: "runtime", MetallibHash: "metal", PolicyGeneration: 7,
		VerifiedAt: now, CertifiedProcessEvidence: certificate,
	}
}

func TestProcessEvidenceChallengeIsOneUseAndSessionBound(t *testing.T) {
	p := &Provider{ID: "session-1", Status: StatusOnline}
	expiry := time.Now().Add(time.Minute)
	state := ProcessEvidenceChallengeState{
		Version: protocol.ProcessEvidenceV1, CoordinatorSessionID: "session-1",
		ChallengeGeneration: "generation", ExpiresAt: expiry,
		ExpiresAtRaw: expiry.Format(time.RFC3339Nano),
	}
	if !p.BeginProcessEvidenceChallenge(state) {
		t.Fatal("valid live challenge was rejected")
	}
	if got := p.ConsumeProcessEvidenceChallenge(); got.ChallengeGeneration != "generation" {
		t.Fatalf("consume got %+v", got)
	}
	if replay := p.ConsumeProcessEvidenceChallenge(); replay.Version != "" {
		t.Fatalf("replay retained challenge state: %+v", replay)
	}
	state.CoordinatorSessionID = "other-session"
	if p.BeginProcessEvidenceChallenge(state) {
		t.Fatal("cross-session challenge was accepted")
	}
}

func TestCertifiedProcessEvidenceGrantAndExpiry(t *testing.T) {
	now := time.Now().UTC()
	p, evidence := certifiedProvider(now)
	if !p.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("valid certified process evidence was rejected")
	}
	certificate, ok := p.CertifiedProcessEvidenceSnapshot()
	if !ok || certificate.ChallengeGeneration != "generation" {
		t.Fatalf("certificate snapshot missing: %+v, %v", certificate, ok)
	}

	p.ClearApplicationEvidence()
	evidence.CertifiedProcessEvidence.ExpiresAt = now.Add(-time.Second)
	if p.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("expired process certificate was installed")
	}
}

func TestPolicyGenerationInvalidatesCertifiedProcessEvidence(t *testing.T) {
	now := time.Now().UTC()
	p, evidence := certifiedProvider(now)
	if !p.GrantApplicationEvidenceIfNotUntrusted(evidence) {
		t.Fatal("precondition: certificate grant failed")
	}
	r := &Registry{providers: map[string]*Provider{p.ID: p}}
	r.SetReleasePolicyGeneration(8, true)
	if _, ok := p.CertifiedProcessEvidenceSnapshot(); ok {
		t.Fatal("release policy generation retained stale process certificate")
	}
	if _, ok := p.ApplicationEvidenceSnapshot(); ok {
		t.Fatal("release policy generation retained stale application evidence")
	}
}

func TestDisconnectAndReconnectCannotCarryProcessCertificate(t *testing.T) {
	r := New(testLogger())
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: BackendMLXSwift,
		ProcessEvidenceVersion: protocol.ProcessEvidenceV1,
	}
	first := r.Register("session", nil, msg)
	first.mu.Lock()
	first.ApplicationEvidence = ApplicationEvidence{
		EvidenceGeneration: 1,
		CertifiedProcessEvidence: CertifiedProcessEvidence{
			Version:              protocol.ProcessEvidenceV1,
			CoordinatorSessionID: "session",
		},
	}
	first.processEvidenceChallenge = ProcessEvidenceChallengeState{
		Version:              protocol.ProcessEvidenceV1,
		CoordinatorSessionID: "session", ChallengeGeneration: "generation",
		ExpiresAt: time.Now().Add(time.Minute), ExpiresAtRaw: "expiry",
	}
	first.mu.Unlock()

	r.Disconnect("session")
	reconnected := r.Register("session", nil, msg)
	if reconnected == first {
		t.Fatal("disconnect reused the old live Provider generation")
	}
	if _, ok := reconnected.CertifiedProcessEvidenceSnapshot(); ok {
		t.Fatal("reconnect restored a process certificate")
	}
	if state := reconnected.ConsumeProcessEvidenceChallenge(); state.Version != "" {
		t.Fatalf("reconnect restored challenge state: %+v", state)
	}
}
