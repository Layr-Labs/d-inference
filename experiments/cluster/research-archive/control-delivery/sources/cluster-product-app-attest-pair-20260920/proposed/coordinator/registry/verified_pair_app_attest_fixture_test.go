package registry

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// These tests seed the output of the separate real V3 verifier. They exercise
// registry/connection ownership, not Apple verification or physical cleanup.
func pairTestAppAttest(t *testing.T, r *Registry, p *Provider, machine string) AppAttestServingAuthorization {
	t.Helper()
	r.SetAppAttestServingPolicy(true, 7)
	p.RequireVerifiedMachineIdentity()
	p.mu.Lock()
	p.AccountID = "pair-account"
	p.Attested, p.MDAVerified, p.SEKeyBound = false, false, false
	p.CodeAttested, p.FreshCodeAttested, p.ChallengeVerifiedSIP = false, false, false
	p.TrustLevel = TrustNone
	p.LastChallengeVerified = time.Time{}
	p.ApplicationEvidence = ApplicationEvidence{}
	p.RuntimeVerified, p.RuntimeManifestChecked, p.MetallibVerified = true, true, true
	p.AttestationResult.SecureEnclaveAvailable = false
	p.AttestationResult.SerialNumber = "unverified-claim"
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	p.AttestationResult.MetallibHash = strings.Repeat("b", 64)
	p.AttestationResult.ChipFamily = p.Hardware.ChipFamily
	p.AttestationResult.RuntimeCapabilities = append([]string(nil), p.ReportedRuntimeCapabilities...)
	p.TemplateHashes = map[string]string{"mlx_metallib": strings.Repeat("b", 64)}
	now := time.Now()
	lease := AppAttestServingAuthorization{AccountID: p.AccountID, MachineID: machine, CredentialID: "credential-" + machine,
		ConnectionID: p.ID, ProofSessionID: "proof-" + machine, Endpoint: p.PublicKey, PolicyGeneration: 7, IssuedAt: now, ValidUntil: now.Add(time.Minute),
		MachineModel: p.Hardware.MachineModel, MemoryGB: p.Hardware.MemoryGB,
		VerifiedControlPublicKey: p.AttestationResult.PublicKey, VerifiedBinaryHash: p.AttestationResult.BinaryHash, VerifiedMetallibHash: p.AttestationResult.MetallibHash}
	p.mu.Unlock()
	if !r.BindVerifiedMachineIdentity(p, lease.AccountID, machine) || !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("synthetic verified lease setup")
	}
	return lease
}
func appAttestPairFixture(t *testing.T) (*Registry, [2]*Provider, VerifiedPairRequest, [2]AppAttestServingAuthorization) {
	t.Helper()
	r, p, request := pairTestRegistry(t)
	leases := [2]AppAttestServingAuthorization{pairTestAppAttest(t, r, p[0], "machine-a"), pairTestAppAttest(t, r, p[1], "machine-b")}
	return r, p, request, leases
}
func pairTestRequirePhase(t *testing.T, r *Registry, h *VerifiedPairHandle, want VerifiedPairPhase) {
	t.Helper()
	r.mu.RLock()
	got := h.state.phase
	r.mu.RUnlock()
	if got != want {
		t.Fatalf("phase %s want %s", got, want)
	}
}
func appPairSign(t *testing.T, rank int, bytes []byte) string {
	t.Helper()
	seed := []byte("serial-a")
	if rank == 1 {
		seed = []byte("serial-b")
	}
	d := new(big.Int).SetBytes(seed)
	x, y := elliptic.P256().ScalarBaseMult(seed)
	key := &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, D: d}
	digest := sha256.Sum256(bytes)
	sig, err := ecdsa.SignASN1(rand.Reader, key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(sig)
}
func appPairMessage(t *testing.T, f *nativePairFixture, s *NativePairSession, rank int, kind string, payload []byte) *protocol.NativePairMessage {
	t.Helper()
	f.c.mu.Lock()
	sequence := f.n[rank].inboundSequence + 1
	f.c.mu.Unlock()
	m := &protocol.NativePairMessage{Type: kind, Version: 1, MemberNonce: f.n[rank].nonce, Epoch: hex.EncodeToString(s.membership.Epoch[:]), Generation: s.membership.Generation, Sequence: sequence, Payload: base64.StdEncoding.EncodeToString(payload)}
	b, err := m.SigningBytes()
	if err != nil {
		t.Fatal(err)
	}
	m.Signature = appPairSign(t, rank, b)
	return m
}
func appPairIntent(t *testing.T, f *nativePairFixture, rank int) *protocol.NativePairIntentMessage {
	t.Helper()
	canonical, err := canonicalNativeRuntimeApproval(f.policy)
	if err != nil {
		t.Fatal(err)
	}
	v := protocol.NativePairIntent{ClusterID: "app-pair", ApprovalID: f.policy.ID, PolicySHA256: sha256.Sum256(canonical), MemberIDs: [2]string{"a", "b"}, Rank: uint8(rank), LifetimeSeconds: 300}
	for i, p := range f.p {
		p.mu.Lock()
		raw, err := base64.StdEncoding.DecodeString(p.AttestationResult.PublicKey)
		p.mu.Unlock()
		if err != nil {
			t.Fatal(err)
		}
		v.SignerSHA256[i] = sha256.Sum256(raw)
	}
	raw, err := v.Canonical()
	if err != nil {
		t.Fatal(err)
	}
	f.c.mu.Lock()
	sequence := f.n[rank].inboundSequence + 1
	f.c.mu.Unlock()
	m := &protocol.NativePairIntentMessage{Type: protocol.TypeNativePairIntent, Version: 1, MemberNonce: f.n[rank].nonce, Sequence: sequence, Payload: base64.StdEncoding.EncodeToString(raw)}
	b, err := m.SigningBytes()
	if err != nil {
		t.Fatal(err)
	}
	m.Signature = appPairSign(t, rank, b)
	return m
}
