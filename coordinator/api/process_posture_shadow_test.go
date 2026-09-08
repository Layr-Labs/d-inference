package api

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func shadowPostureProvider(t *testing.T, s *Server, node, se string) *registry.Provider {
	t.Helper()
	p := s.registry.Register("shadow-provider", nil, &protocol.RegisterMessage{PublicKey: node, Version: "0.9.0", Backend: "mlx-swift", APNsDeviceToken: "token"})
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: se, SerialNumber: "SERIAL", BinaryHash: trHashA, SIPEnabled: true, SecureBootEnabled: true})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.ChallengeVerifiedSIP = true
	p.Mu().Unlock()
	return p
}

type shadowTrustSnapshot struct {
	Trust                registry.TrustLevel
	Status               registry.ProviderStatus
	MDA, SE, Code, Fresh bool
	Reason               string
	Device               registry.DeviceEvidence
	Proof                *attestation.MDAResult
	Chain                [][]byte
	Epoch                uint64
}

func snapshotShadowTrust(p *registry.Provider) shadowTrustSnapshot {
	epoch := p.HardUntrustEpoch()
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return shadowTrustSnapshot{p.TrustLevel, p.Status, p.MDAVerified, p.SEKeyBound, p.CodeAttested, p.FreshCodeAttested, p.MDMFailureReason, p.DeviceEvidence, p.MDAResult, p.MDACertChain, epoch}
}

func TestProcessPostureShadowEvaluatorNeverMutatesTrustOrDurableEvidence(t *testing.T) {
	s := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{ProcessPostureMode: ProcessPostureShadow}, quietLogger())
	t.Cleanup(s.Close)
	node, _, _, se := providerKeyMaterial(t)
	p := shadowPostureProvider(t, s, node, se)
	p.SetFreshCodeAttested()
	s.codeAttestThrottle.recordAttestedForProcess(se, "0.9.0", "token", node, trHashA)
	nonce, _ := attestation.ProcessPostureNonce(se, node)
	issuer := newMDATestIssuer(t)
	defer attestation.OverrideRootCAForTest(issuer.root)()
	good := issuer.mint(t, "SERIAL", nonce, time.Now().Add(time.Hour))
	legacyNonce := sha256.Sum256([]byte(se))
	legacy := issuer.mint(t, "SERIAL", legacyNonce[:], time.Now().Add(time.Hour))
	// Re-sign a leaf with SIP disabled to exercise a valid, bound negative proof.
	leaf, err := x509.ParseCertificate(good[0])
	if err != nil {
		t.Fatal(err)
	}
	leaf.ExtraExtensions = leaf.Extensions
	for i, ext := range leaf.ExtraExtensions {
		if ext.Id.Equal(attestation.OIDSIPStatus) {
			leaf.ExtraExtensions[i].Value, _ = asn1.Marshal(1)
		}
	}
	badDER, err := x509.CreateCertificate(rand.Reader, leaf, issuer.root, leaf.PublicKey, issuer.key)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name  string
		chain [][]byte
		want  string
	}{
		{"ready", good, "ready"}, {"bad_posture", [][]byte{badDER}, "posture_mismatch"}, {"legacy", legacy, "legacy_nonce"}, {"missing", nil, "missing_proof"}, {"invalid", [][]byte{[]byte("invalid")}, "invalid_chain"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			before := snapshotShadowTrust(p)
			rowsBefore, _ := s.store.ListProviderTrustReuse(context.Background())
			observed := s.observeProcessPosture(p, *p.GetAttestationResult(), "UDID-1", tc.chain, true, "proof_install")
			if observed.reason != tc.want {
				t.Fatalf("observation=%+v", observed)
			}
			if s.installProcessPosture(p, *p.GetAttestationResult(), "UDID-1", tc.chain, true) {
				t.Fatal("shadow installed strict proof")
			}
			if s.completeProcessHardwareTrust(p) {
				t.Fatal("shadow completed strict hardware grant")
			}
			if after := snapshotShadowTrust(p); !reflect.DeepEqual(before, after) {
				t.Fatalf("trust mutated: before=%+v after=%+v", before, after)
			}
			rowsAfter, _ := s.store.ListProviderTrustReuse(context.Background())
			if !reflect.DeepEqual(rowsBefore, rowsAfter) {
				t.Fatal("shadow wrote durable authorization or revocation")
			}
		})
	}
	if _, _, ready := p.ProcessPostureReady(); ready {
		t.Fatal("observation became installed posture")
	}
}

func TestProcessPostureShadowLegacyCertificateReusesWithoutIssuance(t *testing.T) {
	s := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{ProcessPostureMode: ProcessPostureShadow}, quietLogger())
	t.Cleanup(s.Close)
	node, _, _, se := providerKeyMaterial(t)
	p := shadowPostureProvider(t, s, node, se)
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.Mu().Unlock()
	legacy := sha256.Sum256([]byte(se))
	chain, root := mintMDALeafChain(t, "SERIAL", legacy[:])
	defer attestation.OverrideRootCAForTest(root)()
	data, _ := json.Marshal(chain)
	p.StageMDAChainFromJSON(data)
	// nil mdmClient makes any new issuance attempt fail immediately.
	s.verifyAppleDeviceAttestation(context.Background(), p.ID, p, *p.GetAttestationResult(), "UDID-1")
	if !mdaVerified(p) || p.GetTrustLevel() != registry.TrustHardware {
		t.Fatal("shadow changed baseline cached proof behavior")
	}
	if got := s.evaluateProcessPosture(p, *p.GetAttestationResult(), "", chain, false); got.allowed || got.reason != "legacy_nonce" {
		t.Fatalf("legacy proof reported as current: %+v", got)
	}
	if !strings.Contains(s.metrics.Snapshot().RenderProm(), `reason="legacy_nonce"`) {
		t.Fatal("missing legacy coverage observation")
	}
}

func TestProcessPostureShadowSecurityInfoKeepsBaselineGrantAndRevocation(t *testing.T) {
	for _, bad := range []bool{false, true} {
		t.Run(map[bool]string{false: "grant", true: "revoke"}[bad], func(t *testing.T) {
			fake := &fakeMDMServer{device: &mdm.DeviceInfo{SerialNumber: "SERIAL-1", UDID: "UDID-1", EnrollmentStatus: true}, commandUUID: "shadow-security", failMDARawCommand: true}
			s, p := mdmReliabilityServer(t, fake, ServerConfig{ProcessPostureMode: ProcessPostureShadow})
			s.SeedTrustReuseCache(context.Background())
			p.SetMDMFailureReason("securityinfo-timeout")
			deliverWebhookWhenPushed(s, fake, "UDID-1", "shadow-security", !bad, true)
			outcome := s.verifyProviderViaMDM(context.Background(), p.ID, p, attestResultOf(p))
			if bad {
				if outcome != mdmVerifyTerminal || p.GetStatus() != registry.StatusUntrusted {
					t.Fatal("shadow disabled baseline bad-SecurityInfo revocation")
				}
			} else if outcome != mdmVerifySecurityInfoPassed || p.GetTrustLevel() != registry.TrustHardware || p.GetMDMFailureReason() != "" {
				t.Fatalf("baseline grant changed: outcome=%v state=%+v", outcome, snapshotShadowTrust(p))
			}
		})
	}
}

func TestProcessPostureShadowCrossKeyResumeStaysUnproven(t *testing.T) {
	s := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{ProcessPostureMode: ProcessPostureShadow}, quietLogger())
	t.Cleanup(s.Close)
	fastBudgets(s)
	k1, _, sign, se := providerKeyMaterial(t)
	k2, private2, _, _ := providerKeyMaterial(t)
	p := crossVersionProvider(k2, se, "0.6.14")
	armCrossVersionApplicationEvidence(t, s, p, se)
	p.ChallengeVerifiedSIP = true
	s.codeAttestThrottle.recordAttestedForProcess(se, "0.6.13", p.APNsDeviceToken, k1, trHashB)
	pushes := 0
	s.SetCodeAttestor(&fakeCodeAttestor{onSend: func(_, _, _, _ string) error { pushes++; return nil }})
	s.codeResumeSender = func(_ string, message protocol.CodeAttestationResumeChallenge) error {
		return completeResumeRoundTrip(t, s, p, "p2", private2, sign, message)
	}
	if !s.tryCrossVersionReuse(context.Background(), "p2", p) {
		t.Fatal("shadow changed baseline cross-key resumption")
	}
	if pushes != 0 || !p.GetFreshCodeAttested() {
		t.Fatal("baseline resume failed")
	}
	if s.codeAttestThrottle.reuseProcessIdentity(se, p.APNsDeviceToken, k2) {
		t.Fatal("legacy resume overwrote original process provenance")
	}
	nonce, _ := attestation.ProcessPostureNonce(se, k2)
	ar := p.GetAttestationResult()
	chain, root := mintMDALeafChain(t, ar.SerialNumber, nonce)
	defer attestation.OverrideRootCAForTest(root)()
	observation := s.evaluateProcessPosture(p, *ar, "UDID-1", chain, true)
	if observation.allowed || observation.reason != "process_identity_unproven" {
		t.Fatalf("cross-key resume treated as original-key continuity: %+v", observation)
	}
}

func TestProcessPostureShadowTimedReusePreservesBaselineAndRevocation(t *testing.T) {
	for _, mode := range []ProcessPostureMode{ProcessPostureShadow, ProcessPostureEnforce} {
		t.Run(string(mode), func(t *testing.T) {
			s := NewServer(registry.New(quietLogger()), store.NewMemory(store.Config{}), ServerConfig{ProcessPostureMode: mode}, quietLogger())
			t.Cleanup(s.Close)
			s.mdmClient = dummyMDMClient()
			node, _, _, se := providerKeyMaterial(t)
			p := shadowPostureProvider(t, s, node, se)
			if mode == ProcessPostureEnforce {
				p.RequireProcessPosture()
			}
			s.trustReuseCache.recordTrust(store.ProviderTrustReuse{SEPubKey: se, Serial: "SERIAL", TrustLevel: string(registry.TrustHardware), LastVerifiedBinaryHash: trHashA, SIPEnabled: true, SecureBootFull: true, MDAUDID: "UDID-1", HardwareProofVerifiedAt: time.Now()})
			allowed := s.tryTrustReuseFastSkip(p.ID, p, goodFastSkipResp(), true)
			if allowed != (mode == ProcessPostureShadow) {
				t.Fatalf("timed reuse=%v", allowed)
			}
			if mode == ProcessPostureShadow && p.GetTrustLevel() != registry.TrustHardware {
				t.Fatal("baseline timed grant lost")
			}
			s.trustReuseCache.invalidateReuse(se, "test-revocation")
			if s.tryTrustReuseFastSkip(p.ID, p, goodFastSkipResp(), true) {
				t.Fatal("mode bypassed baseline revocation")
			}
		})
	}
}
