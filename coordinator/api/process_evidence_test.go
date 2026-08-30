package api

import (
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const processEvidenceTestBinary = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const processEvidenceTestMetallib = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const processEvidenceTestRuntime = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

func signProcessEvidenceForTest(
	t *testing.T, processKey string, in attestation.ProcessEvidenceCanonicalInput,
) string {
	t.Helper()
	raw, ok := testAttestationChallengeKeys.Load(processKey)
	if !ok {
		t.Fatalf("missing signer for %q", processKey)
	}
	priv := raw.(*ecdsa.PrivateKey)
	canonical, err := attestation.BuildProcessEvidenceCanonicalV1(in)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(canonical)
	r, s, err := ecdsa.Sign(rand.Reader, priv, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	der, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(der)
}

func processEvidenceVerifierFixture(t *testing.T) (
	*Server, *registry.Provider, *pendingChallenge, protocol.AttestationResponseMessage,
) {
	t.Helper()
	processKey := base64.StdEncoding.EncodeToString(make([]byte, 32))
	raw := buildTestAttestationJSON(t, processKey, processEvidenceTestBinary, "SERIAL-1")
	result, err := attestation.VerifyJSON(raw)
	if err != nil || !result.Valid {
		t.Fatalf("verify fixture attestation: %+v %v", result, err)
	}
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.releaseTrustPolicy.Store(&releaseTrustPolicySnapshot{
		Generation: 9, Required: true,
		ByBinaryHash: map[string][]approvedReleasePolicy{
			processEvidenceTestBinary: {{
				Version: "0.8.15", Platform: "macos-arm64", Backend: registry.BackendMLXSwift,
				BinaryHash:  processEvidenceTestBinary,
				RuntimeHash: processEvidenceTestRuntime, MetallibHash: processEvidenceTestMetallib,
			}},
		},
	})
	provider := &registry.Provider{
		ID: "session-1", PublicKey: processKey, APNsDeviceToken: "apns-token",
		Version: "0.8.15", Backend: registry.BackendMLXSwift,
		Status: registry.StatusOnline, ProcessEvidenceVersion: protocol.ProcessEvidenceV1,
		RuntimeVerified: true, RuntimeManifestChecked: true, MetallibVerified: true,
		AttestationResult: &result,
	}
	now := time.Now().UTC()
	expires := now.Add(time.Minute).Format(time.RFC3339Nano)
	if !provider.BeginProcessEvidenceChallenge(registry.ProcessEvidenceChallengeState{
		Version: protocol.ProcessEvidenceV1, CoordinatorSessionID: provider.ID,
		ChallengeGeneration: "generation-1", ExpiresAt: now.Add(time.Minute),
		ExpiresAtRaw: expires,
	}) {
		t.Fatal("begin challenge")
	}
	truth := true
	pc := &pendingChallenge{nonce: "nonce-1", timestamp: "2026-08-30T12:00:00Z", processEvidenceV1: true}
	resp := protocol.AttestationResponseMessage{
		Type: protocol.TypeAttestationResponse, Nonce: pc.nonce,
		Signature: testChallengeSignature(pc.nonce, pc.timestamp, processKey),
		PublicKey: processKey, ProcessEvidenceVersion: protocol.ProcessEvidenceV1,
		CoordinatorSessionID: provider.ID, ChallengeGeneration: "generation-1",
		ChallengeExpiresAt: expires, SEPublicKey: result.PublicKey,
		SerialNumber: result.SerialNumber, ProviderVersion: provider.Version,
		ProviderPlatform: "macos-arm64", ProviderBackend: provider.Backend,
		BinaryHash: processEvidenceTestBinary, RuntimeHash: processEvidenceTestRuntime,
		MetallibHash:   processEvidenceTestMetallib,
		TemplateHashes: map[string]string{"mlx_metallib": processEvidenceTestMetallib},
		SIPEnabled:     &truth, SecureBootEnabled: &truth,
	}
	resp.StatusSignature = testStatusSignature(t, attestation.StatusCanonicalInput{
		Nonce: pc.nonce, Timestamp: pc.timestamp,
		RDMADisabled: resp.RDMADisabled, SIPEnabled: resp.SIPEnabled,
		SecureBootEnabled: resp.SecureBootEnabled, BinaryHash: resp.BinaryHash,
		RuntimeHash: resp.RuntimeHash, TemplateHashes: resp.TemplateHashes,
	}, processKey)
	resp.ProcessEvidenceSignature = signProcessEvidenceForTest(t, processKey,
		attestation.ProcessEvidenceCanonicalInput{
			CoordinatorNonce: pc.nonce, CoordinatorTimestamp: pc.timestamp,
			CoordinatorSessionID: resp.CoordinatorSessionID,
			ChallengeGeneration:  resp.ChallengeGeneration,
			EvidenceExpiresAt:    resp.ChallengeExpiresAt,
			SEPublicKey:          resp.SEPublicKey, SerialNumber: resp.SerialNumber,
			ProcessPublicKey: resp.PublicKey, BinaryHash: resp.BinaryHash,
			ProviderVersion: resp.ProviderVersion, ProviderPlatform: resp.ProviderPlatform,
			ProviderBackend: resp.ProviderBackend, RuntimeHash: resp.RuntimeHash,
			MetallibHash: resp.MetallibHash, SIPEnabled: resp.SIPEnabled,
			SecureBootEnabled: resp.SecureBootEnabled,
		})
	return srv, provider, pc, resp
}

func TestVerifyProcessEvidenceV1InstallsAuthoritativeSnapshotInput(t *testing.T) {
	srv, provider, pc, resp := processEvidenceVerifierFixture(t)
	fact, evidence, reason := srv.verifyProcessEvidenceV1(provider, pc, &resp, time.Now().UTC())
	if reason != processEvidenceReasonOK {
		t.Fatalf("verification failed: %s", reason)
	}
	if !fact.Approved || evidence.CertifiedProcessEvidence.Version != protocol.ProcessEvidenceV1 ||
		evidence.CertifiedProcessEvidence.CoordinatorSessionID != provider.ID ||
		evidence.CertifiedProcessEvidence.ProcessPublicKey != provider.PublicKey ||
		evidence.PolicyGeneration != 9 {
		t.Fatalf("bad certified evidence: fact=%+v evidence=%+v", fact, evidence)
	}
}

func TestVerifyProcessEvidenceV1MutationAndDowngradeMatrix(t *testing.T) {
	mutations := map[string]struct {
		mutate func(*protocol.AttestationResponseMessage)
		want   processEvidenceReason
	}{
		"process_key":     {func(r *protocol.AttestationResponseMessage) { r.PublicKey += "x" }, processEvidenceReasonProcessKeyMismatch},
		"se":              {func(r *protocol.AttestationResponseMessage) { r.SEPublicKey += "x" }, processEvidenceReasonIdentityMismatch},
		"serial":          {func(r *protocol.AttestationResponseMessage) { r.SerialNumber += "x" }, processEvidenceReasonIdentityMismatch},
		"session":         {func(r *protocol.AttestationResponseMessage) { r.CoordinatorSessionID += "x" }, processEvidenceReasonSessionMismatch},
		"generation":      {func(r *protocol.AttestationResponseMessage) { r.ChallengeGeneration += "x" }, processEvidenceReasonGenerationMismatch},
		"expiry":          {func(r *protocol.AttestationResponseMessage) { r.ChallengeExpiresAt += "x" }, processEvidenceReasonExpiryMismatch},
		"binary":          {func(r *protocol.AttestationResponseMessage) { r.BinaryHash = processEvidenceTestMetallib }, processEvidenceReasonReleaseMismatch},
		"version":         {func(r *protocol.AttestationResponseMessage) { r.ProviderVersion += "x" }, processEvidenceReasonReleaseMismatch},
		"backend":         {func(r *protocol.AttestationResponseMessage) { r.ProviderBackend += "x" }, processEvidenceReasonReleaseMismatch},
		"runtime":         {func(r *protocol.AttestationResponseMessage) { r.RuntimeHash = processEvidenceTestBinary }, processEvidenceReasonSignatureInvalid},
		"metallib":        {func(r *protocol.AttestationResponseMessage) { r.MetallibHash = processEvidenceTestBinary }, processEvidenceReasonRuntimeMismatch},
		"sip":             {func(r *protocol.AttestationResponseMessage) { v := false; r.SIPEnabled = &v }, processEvidenceReasonPostureUnsafe},
		"secure_boot":     {func(r *protocol.AttestationResponseMessage) { v := false; r.SecureBootEnabled = &v }, processEvidenceReasonPostureUnsafe},
		"signature":       {func(r *protocol.AttestationResponseMessage) { r.ProcessEvidenceSignature += "x" }, processEvidenceReasonSignatureInvalid},
		"omitted_version": {func(r *protocol.AttestationResponseMessage) { r.ProcessEvidenceVersion = "" }, processEvidenceReasonMixedVersion},
	}
	for name, test := range mutations {
		t.Run(name, func(t *testing.T) {
			srv, provider, pc, resp := processEvidenceVerifierFixture(t)
			test.mutate(&resp)
			_, _, reason := srv.verifyProcessEvidenceV1(provider, pc, &resp, time.Now().UTC())
			if reason != test.want {
				t.Fatalf("reason=%s want=%s", reason, test.want)
			}
		})
	}
}

func TestVerifyProcessEvidenceV1RejectsExpiredAndReplay(t *testing.T) {
	srv, provider, pc, resp := processEvidenceVerifierFixture(t)
	_, _, reason := srv.verifyProcessEvidenceV1(provider, pc, &resp, time.Now().Add(2*time.Minute))
	if reason != processEvidenceReasonExpired {
		t.Fatalf("expired reason=%s", reason)
	}
	_, _, reason = srv.verifyProcessEvidenceV1(provider, pc, &resp, time.Now().UTC())
	if reason != processEvidenceReasonMissingChallenge {
		t.Fatalf("replay reason=%s", reason)
	}
}

func TestProcessEvidenceVersionFloorAndGeneration(t *testing.T) {
	legacy := &registry.Provider{Version: "0.8.15"}
	if providerRequiresProcessEvidenceV1(legacy) {
		t.Fatal("legacy version below floor unexpectedly required v1")
	}
	floored := &registry.Provider{Version: processEvidenceProviderVersionFloor}
	if !providerRequiresProcessEvidenceV1(floored) {
		t.Fatal("provider at compatibility floor could downgrade to legacy")
	}
	advertised := &registry.Provider{
		Version: "0.8.15", ProcessEvidenceVersion: protocol.ProcessEvidenceV1,
	}
	if !providerRequiresProcessEvidenceV1(advertised) {
		t.Fatal("advertised v1 capability could downgrade to legacy")
	}
	first, err := generateChallengeGeneration()
	if err != nil {
		t.Fatal(err)
	}
	second, err := generateChallengeGeneration()
	if err != nil {
		t.Fatal(err)
	}
	if first == "" || second == "" || first == second {
		t.Fatalf("challenge generations not fresh: %q %q", first, second)
	}
}
