package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func processPostureProvider(t *testing.T, s *Server, id, nodeKey, seKey string) *registry.Provider {
	t.Helper()
	p := s.registry.Register(id, nil, &protocol.RegisterMessage{
		PublicKey: nodeKey, Backend: "mlx-swift", Version: "0.9.0", APNsDeviceToken: "token",
	})
	p.RequireProcessPosture()
	p.SetAttestationResult(&attestation.VerificationResult{
		Valid: true, PublicKey: seKey, SerialNumber: "SERIAL", BinaryHash: trHashA,
		SIPEnabled: true, SecureBootEnabled: true,
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.Version = "0.9.0"
	p.ChallengeVerifiedSIP = true
	p.RuntimeVerified, p.RuntimeManifestChecked, p.MetallibVerified = true, true, true
	p.Mu().Unlock()
	p.SignalApplicationProofSettled()
	return p
}

func TestProcessPostureCoordinatorRestartResumesButRebootDoesNot(t *testing.T) {
	logger := quietLogger()
	mem := store.NewMemory(store.Config{})
	s := NewServer(registry.New(logger), mem, ServerConfig{}, logger)
	fastBudgets(s)
	s.SeedCodeAttestCache(context.Background())
	k1, private1, signingKey, seKey := providerKeyMaterial(t)
	p := processPostureProvider(t, s, "initial", k1, seKey)
	s.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, pub, nonce string) error {
		return completeRoundTrip(t, s, p, p.ID, private1, signingKey, pub, nonce)
	}})
	s.codeAttestLoop(context.Background(), p.ID, p)
	if !p.GetFreshCodeAttested() {
		t.Fatal("initial process failed APNs possession proof")
	}
	if p.GetTrustLevel() == registry.TrustHardware {
		t.Fatal("code proof alone granted hardware")
	}
	nonce, err := attestation.ProcessPostureNonce(seKey, k1)
	if err != nil {
		t.Fatal(err)
	}
	chain, root := mintMDALeafChain(t, "SERIAL", nonce)
	defer attestation.OverrideRootCAForTest(root)()
	if !s.installProcessPosture(p, *p.GetAttestationResult(), "UDID-1", chain, true) {
		t.Fatal("fresh process posture did not grant")
	}

	// A distinct coordinator restores durable evidence. A long outage does not
	// imply reboot; the OLD private key is the continuity proof.
	restarted := NewServer(registry.New(logger), mem, ServerConfig{}, logger)
	fastBudgets(restarted)
	if !waitForCond(time.Second, func() bool { rows, _ := mem.ListCodeAttestations(context.Background()); return len(rows) > 0 }) {
		t.Fatal("code evidence was not persisted")
	}
	rows, err := mem.ListCodeAttestations(context.Background())
	if err != nil || len(rows) == 0 {
		t.Fatalf("missing durable code proof: %v", err)
	}
	for i := range rows {
		rows[i].AttestedAt = time.Now().Add(-24 * time.Hour)
	}
	restarted.codeAttestThrottle.seed(rows)
	pushes := 0
	restarted.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { pushes++; return nil }})
	resumed := processPostureProvider(t, restarted, "same-process", k1, seKey)
	restarted.stageDurableMDAChain(resumed, "SERIAL")
	restarted.codeResumeSender = func(_ string, message protocol.CodeAttestationResumeChallenge) error {
		return completeResumeRoundTrip(t, restarted, resumed, resumed.ID, private1, signingKey, message)
	}
	restarted.codeAttestLoop(context.Background(), resumed.ID, resumed)
	if pushes != 0 || resumed.GetTrustLevel() != registry.TrustHardware {
		t.Fatalf("same process: pushes=%d trust=%s", pushes, resumed.GetTrustLevel())
	}

	// Reboot: same persistent signing key/token and spoofed good fields, but a
	// new encryption key. Even granting a fresh APNs proof cannot reuse the old
	// posture certificate. No wall-clock window or release hash overrides it.
	k2, _, _, _ := providerKeyMaterial(t)
	booted := processPostureProvider(t, restarted, "new-process", k2, seKey)
	booted.SetFreshCodeAttested()
	data, _ := json.Marshal(chain)
	booted.StageMDAChainFromJSON(data)
	if restarted.attachCachedMDAProof(booted.ID, booted, *booted.GetAttestationResult()) {
		t.Fatal("new process inherited old posture")
	}
	if restarted.tryTrustReuseFastSkip(booted.ID, booted, goodFastSkipResp(), true) {
		t.Fatal("timed cache bypassed process boundary")
	}
	if booted.GetTrustLevel() == registry.TrustHardware {
		t.Fatal("rebooted process was hardware trusted")
	}
}

func TestProcessPostureLegacyCertificateAndMissingPossessionFailClosed(t *testing.T) {
	logger := quietLogger()
	s := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	node, _, _, se := providerKeyMaterial(t)
	p := processPostureProvider(t, s, "p", node, se)
	legacy := sha256.Sum256([]byte(se))
	chain, root := mintMDALeafChain(t, "SERIAL", legacy[:])
	restore := attestation.OverrideRootCAForTest(root)
	p.SetFreshCodeAttested()
	if s.installProcessPosture(p, *p.GetAttestationResult(), "UDID-1", chain, false) {
		t.Fatal("legacy persistent-key certificate granted")
	}
	restore()
	nonce, _ := attestation.ProcessPostureNonce(se, node)
	chain, root = mintMDALeafChain(t, "SERIAL", nonce)
	defer attestation.OverrideRootCAForTest(root)()
	p.SetCodeAttested(false)
	if s.installProcessPosture(p, *p.GetAttestationResult(), "UDID-1", chain, true) {
		t.Fatal("certificate without key possession granted")
	}
	if p.GetTrustLevel() == registry.TrustHardware {
		t.Fatal("missing process proof routed")
	}
	if p.GrantHardwareEvidenceAtEpochIfNotUntrusted(registry.DeviceEvidence{}, p.HardUntrustEpoch()) {
		t.Fatal("alternate grant bypassed posture gate")
	}
}

func TestProcessPostureResumeCannotClearRevocation(t *testing.T) {
	logger := quietLogger()
	s := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	node, _, _, se := providerKeyMaterial(t)
	p := processPostureProvider(t, s, "p", node, se)
	p.SetFreshCodeAttested()
	nonce, _ := attestation.ProcessPostureNonce(se, node)
	chain, root := mintMDALeafChain(t, "SERIAL", nonce)
	defer attestation.OverrideRootCAForTest(root)()
	s.trustReuseCache.invalidateReuse(se, "security-revocation")
	if s.installProcessPosture(p, *p.GetAttestationResult(), "UDID-1", chain, false) {
		t.Fatal("cached certificate cleared revocation")
	}
	if s.installProcessPosture(p, *p.GetAttestationResult(), "UDID-1", chain, true) {
		t.Fatal("old nonce treated as fresh after revocation")
	}

}

func TestProcessPostureMissingAppleMeasurementsRemainPending(t *testing.T) {
	logger := quietLogger()
	s := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	node, _, _, se := providerKeyMaterial(t)
	p := processPostureProvider(t, s, "unknown-posture", node, se)
	p.SetFreshCodeAttested()
	nonce, _ := attestation.ProcessPostureNonce(se, node)
	issuer := newMDATestIssuer(t)
	defer attestation.OverrideRootCAForTest(issuer.root)()
	chain := issuer.mint(t, "SERIAL", nonce, time.Now().Add(time.Hour), true)
	if s.installProcessPosture(p, *p.GetAttestationResult(), "UDID-1", chain, true) {
		t.Fatal("missing measurements granted")
	}
	if p.GetStatus() == registry.StatusUntrusted || p.GetTrustLevel() != registry.TrustSelfSigned || p.GetMDMFailureReason() != "apple-posture-unavailable" {
		t.Fatal("unavailable measurements must stay pending, not become a disabled-SIP verdict")
	}
}
