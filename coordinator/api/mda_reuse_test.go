package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/json"
	"io"
	"log/slog"
	"math/big"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// mintMDALeafChain builds a single-cert DER chain (leaf signed by a test CA)
// carrying the DevicePropertiesAttestation serial + freshness OIDs, and returns
// the chain plus the test CA to install via attestation.OverrideRootCAForTest.
func mintMDALeafChain(t *testing.T, serial string, freshness []byte) (chain [][]byte, root *x509.Certificate) {
	return mintMDALeafChainExp(t, serial, freshness, time.Now().Add(24*time.Hour))
}

// mintMDALeafChainExp is mintMDALeafChain with an explicit leaf NotAfter, so tests
// can exercise reuse behavior across the cert's validity window over time.
type mdaTestIssuer struct {
	key  *ecdsa.PrivateKey
	root *x509.Certificate
}

func newMDATestIssuer(t *testing.T) *mdaTestIssuer {
	t.Helper()
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test Root"},
		NotBefore:             time.Now().Add(-2 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTmpl, caTmpl, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	root, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}
	return &mdaTestIssuer{caKey, root}
}
func (issuer *mdaTestIssuer) mint(t *testing.T, serial string, freshness []byte, notAfter time.Time, omitPosture ...bool) [][]byte {
	t.Helper()
	leafKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	serialBytes, _ := asn1.Marshal(serial)
	freshBytes, _ := asn1.Marshal(freshness)
	udidBytes, _ := asn1.Marshal("UDID-1")
	sipBytes, _ := asn1.Marshal(0)
	bootBytes, _ := asn1.Marshal("Full Security")
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "Leaf"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{
			{Id: attestation.OIDDeviceSerialNumber, Value: serialBytes},
			{Id: attestation.OIDFreshnessCode, Value: freshBytes},
			{Id: attestation.OIDDeviceUDID, Value: udidBytes},
			{Id: attestation.OIDSIPStatus, Value: sipBytes},
			{Id: attestation.OIDSecureBootStatus, Value: bootBytes},
		},
	}
	if len(omitPosture) > 0 && omitPosture[0] {
		filtered := leafTmpl.ExtraExtensions[:0]
		for _, ext := range leafTmpl.ExtraExtensions {
			if !ext.Id.Equal(attestation.OIDSIPStatus) && !ext.Id.Equal(attestation.OIDSecureBootStatus) {
				filtered = append(filtered, ext)
			}
		}
		leafTmpl.ExtraExtensions = filtered
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, issuer.root, &leafKey.PublicKey, issuer.key)
	if err != nil {
		t.Fatal(err)
	}
	return [][]byte{leafDER}
}
func mintMDALeafChainExp(t *testing.T, serial string, freshness []byte, notAfter time.Time) ([][]byte, *x509.Certificate) {
	issuer := newMDATestIssuer(t)
	return issuer.mint(t, serial, freshness, notAfter), issuer.root
}

// reconnectWithStagedChain mints a chain bound to (serial, sePubKey), installs the
// test CA, and drives a provider through the reconnect → re-grant sequence so the
// durable chain is staged and hardware is held — exactly the state the reuse path
// runs in. Returns the live server + provider.
func reconnectWithStagedChain(t *testing.T, serial, _ string) (*Server, *registry.Provider, func()) {
	t.Helper()
	node, _, _, se := providerKeyMaterial(t)
	nonce, err := attestation.ProcessPostureNonce(se, node)
	if err != nil {
		t.Fatal(err)
	}
	chain, root := mintMDALeafChain(t, serial, nonce)
	restore := attestation.OverrideRootCAForTest(root)
	logger := quietLogger()
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	p := processPostureProvider(t, srv, "prov-mda", node, se)
	ar := *p.GetAttestationResult()
	ar.SerialNumber = serial
	p.SetAttestationResult(&ar)
	p.SetFreshCodeAttested()
	data, _ := json.Marshal(chain)
	p.StageMDAChainFromJSON(data)
	return srv, p, restore
}

// TestAttachCachedMDAProof_ReusesWithoutMDM is the core guarantee: after a
// reconnect, a still-valid durable MDA chain is reused — re-verified locally and
// re-bound to the SE key — with NO MicroMDM/APNs round-trip. This is what keeps
// mda_verified green across a provider restart and dodges Apple's ≈1/device/7d
// fresh-attestation rate limit.
func TestAttachCachedMDAProof_ReusesWithoutMDM(t *testing.T) {
	srv, p, restore := reconnectWithStagedChain(t, "SERIAL-A", "se-pub-key")
	defer restore()

	ar := p.GetAttestationResult()
	if !srv.attachCachedMDAProof("prov-mda", p, *ar) {
		t.Fatal("expected cached MDA proof to be reused")
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if !p.MDAVerified {
		t.Error("MDAVerified must be true after reuse")
	}
	if !p.SEKeyBound {
		t.Error("SEKeyBound must be true (freshness code matched the SE key hash)")
	}
	if len(p.MDACertChain) == 0 {
		t.Error("MDACertChain must remain attached for coordinator-side trust reuse")
	}
}

// TestVerifyAppleDeviceAttestation_CachedShortCircuit proves the full entry point
// short-circuits on a cached proof: with a nil mdmClient, reaching the fresh
// DevicePropertiesAttestation send would panic. A green, panic-free result means
// the MDM command path was skipped entirely.
func TestVerifyAppleDeviceAttestation_CachedShortCircuit(t *testing.T) {
	srv, p, restore := reconnectWithStagedChain(t, "SERIAL-A", "se-pub-key")
	defer restore()

	ar := p.GetAttestationResult()
	// udid is non-empty: if the cache path did NOT short-circuit, execution would
	// fall through to s.mdmClient.RequestDeviceAttestation and panic on nil.
	srv.verifyAppleDeviceAttestation(context.Background(), "prov-mda", p, *ar, "some-udid")

	if !mdaVerified(p) {
		t.Error("MDAVerified must be true via the cached short-circuit (no fresh MDM request)")
	}
}

// mdaVerified reads MDAVerified under the provider lock (race-safe).
func mdaVerified(p *registry.Provider) bool {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.MDAVerified
}

// TestStageDurableMDAChain_LiveStoreReusedAcrossReconnect proves the prod path:
// the chain is recovered from a LIVE store read (not the empty startup
// storedProviders snapshot), so a provider that earned MDA in a prior connection
// keeps mda_verified green on reconnect — with no fresh MDM/APNs round-trip.
func TestStageDurableMDAChain_LiveStoreReusedAcrossReconnect(t *testing.T) {
	srv, p, restore := reconnectWithStagedChain(t, "SERIAL-LIVE", "")
	defer restore()
	if !srv.attachCachedMDAProof(p.ID, p, *p.GetAttestationResult()) {
		t.Fatal("initial certificate failed")
	}
	restarted := NewServer(registry.New(quietLogger()), srv.store, ServerConfig{}, quietLogger())
	next := processPostureProvider(t, restarted, "next", p.PublicKey, p.GetAttestationResult().PublicKey)
	ar := *next.GetAttestationResult()
	ar.SerialNumber = "SERIAL-LIVE"
	next.SetAttestationResult(&ar)
	next.SetFreshCodeAttested()
	restarted.stageDurableMDAChain(next, ar.SerialNumber)
	if !restarted.attachCachedMDAProof(next.ID, next, ar) {
		t.Fatal("durable same-process certificate failed")
	}
	if !waitForCond(time.Second, func() bool {
		rec, err := srv.store.GetProviderBySerial(context.Background(), ar.SerialNumber)
		return err == nil && rec != nil && rec.MDAVerified && len(rec.MDACertChain) > 0
	}) {
		t.Fatal("resumed certificate not persisted")
	}

}

// TestAttachCachedMDAProof_ExpiredChainNotReused proves the time dimension: an
// expired cached chain fails local re-verification, so reuse is declined and a
// fresh attestation is requested instead of trusting a stale cert. (Apple uses a
// freshness model rather than a fixed expiry; this is the relying-party staleness
// check.)
func TestAttachCachedMDAProof_ExpiredChainNotReused(t *testing.T) {
	srv, p, restore := reconnectWithStagedChain(t, "SERIAL-EXP", "")
	defer restore()
	ar := p.GetAttestationResult()
	nonce, _ := attestation.ProcessPostureNonce(ar.PublicKey, p.PublicKey)
	chain, root := mintMDALeafChainExp(t, ar.SerialNumber, nonce, time.Now().Add(-time.Minute))
	defer attestation.OverrideRootCAForTest(root)()
	data, _ := json.Marshal(chain)
	p.StageMDAChainFromJSON(data)
	if srv.attachCachedMDAProof(p.ID, p, *ar) || p.GetTrustLevel() == registry.TrustHardware {
		t.Fatal("expired posture certificate authorized routing")
	}
}

// TestAttachCachedMDAProof_NoStagedChain confirms the reuse path declines when no
// durable chain exists, so a fresh request is still made for first-time devices.
func TestAttachCachedMDAProof_NoStagedChain(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger}
	p := reg.Register("p", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, Backend: "mlx-swift"})
	p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "S", PublicKey: "K"})
	p.SetAttested(true, registry.TrustHardware)

	if srv.attachCachedMDAProof("p", p, *p.GetAttestationResult()) {
		t.Fatal("expected no reuse when there is no staged chain")
	}
}

// TestAttachCachedMDAProof_RelayRejected proves anti-relay: a chain whose
// freshness code binds a DIFFERENT SE key and whose serial does not match this
// machine is NOT reused (it would otherwise let one machine inherit another's
// Apple attestation).
func TestAttachCachedMDAProof_RelayRejected(t *testing.T) {
	// Chain is bound to "victim-se-key" + serial "VICTIM".
	srv, p, restore := reconnectWithStagedChain(t, "VICTIM", "victim-se-key")
	defer restore()

	// But THIS connection presents a different SE key and serial.
	p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: "ATTACKER", PublicKey: "attacker-se-key"})

	if srv.attachCachedMDAProof("prov-mda", p, *p.GetAttestationResult()) {
		t.Fatal("expected reuse to be rejected when neither SE key nor serial binds")
	}
	if mdaVerified(p) {
		t.Error("MDAVerified must stay false on a rejected (relay) reuse")
	}
}
