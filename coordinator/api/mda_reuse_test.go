package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
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
func mintMDALeafChainExp(t *testing.T, serial string, freshness []byte, notAfter time.Time) (chain [][]byte, root *x509.Certificate) {
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
	root, err = x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}
	leafKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	serialBytes, _ := asn1.Marshal(serial)
	freshBytes, _ := asn1.Marshal(freshness)
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "Leaf"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{
			{Id: attestation.OIDDeviceSerialNumber, Value: serialBytes},
			{Id: attestation.OIDFreshnessCode, Value: freshBytes},
		},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, root, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	return [][]byte{leafDER}, root
}

// reconnectWithStagedChain mints a chain bound to (serial, sePubKey), installs the
// test CA, and drives a provider through the reconnect → re-grant sequence so the
// durable chain is staged and hardware is held — exactly the state the reuse path
// runs in. Returns the live server + provider.
func reconnectWithStagedChain(t *testing.T, serial, sePubKey string) (*Server, *registry.Provider, func()) {
	t.Helper()
	seHash := sha256.Sum256([]byte(sePubKey))
	chain, root := mintMDALeafChain(t, serial, seHash[:])
	restore := attestation.OverrideRootCAForTest(root)

	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	// mdmClient deliberately nil: the reuse path must never touch it. A fresh
	// DevicePropertiesAttestation send would deref nil and panic, so a green result
	// here proves the rate-limited APNs round-trip was skipped.
	srv := &Server{registry: reg, logger: logger}

	regMsg := &protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "M4 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "m", ModelType: "chat"}},
		Backend:  "mlx-swift",
	}
	p := reg.Register("prov-mda", nil, regMsg)
	p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: serial, PublicKey: sePubKey})

	// Simulate reconnect: the store has a durable chain; RestoreProviderState stages
	// it (capping trust to self_signed). Hardware is then re-earned live.
	chainJSON, _ := json.Marshal(chain)
	reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:           "prov-mda",
		TrustLevel:   string(registry.TrustHardware),
		MDAVerified:  true,
		MDACertChain: chainJSON,
	})
	p.SetAttested(true, registry.TrustHardware)
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
		t.Error("MDACertChain must be attached for the attestation endpoint")
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
	// fall through to s.mdmClient.SendDeviceAttestationCommand and panic on nil.
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
	const serial, sePub = "SERIAL-LIVE", "se-pub-live"
	seHash := sha256.Sum256([]byte(sePub))
	chain, root := mintMDALeafChain(t, serial, seHash[:])
	defer attestation.OverrideRootCAForTest(root)()

	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	mem := store.NewMemory(store.Config{AdminKey: "k"})
	chainJSON, _ := json.Marshal(chain)
	// A previous connection earned MDA and persisted it; the record survives the
	// provider's disconnect.
	if err := mem.UpsertProvider(context.Background(), store.ProviderRecord{
		ID:           "old-session",
		SerialNumber: serial,
		TrustLevel:   string(registry.TrustHardware),
		MDAVerified:  true,
		MDACertChain: chainJSON,
	}); err != nil {
		t.Fatal(err)
	}

	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger, store: mem}

	// New reconnect session: storedProviders is nil/empty (startup snapshot), so the
	// chain must come from the live store read.
	p := reg.Register("new-session", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, Backend: "mlx-swift"})
	p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: serial, PublicKey: sePub})

	srv.stageDurableMDAChain(p, serial)
	if len(p.StagedMDAChain()) == 0 {
		t.Fatal("expected the durable chain to be staged from the live store read")
	}

	p.SetAttested(true, registry.TrustHardware)
	if !srv.attachCachedMDAProof("new-session", p, *p.GetAttestationResult()) {
		t.Fatal("expected reuse of the live-store chain")
	}
	if !mdaVerified(p) {
		t.Error("MDAVerified must be true after reuse via the live store path")
	}

	// The reuse must persist the chain under THIS session's record, so a later
	// reconnect can reuse it again instead of re-hitting Apple's rate limit. Look
	// it up by serial (which now indexes this session) and confirm the chain is
	// durable.
	rec, err := mem.GetProviderBySerial(context.Background(), serial)
	if err != nil || rec == nil {
		t.Fatalf("expected a persisted record for serial after reuse: %v", err)
	}
	if !rec.MDAVerified || len(rec.MDACertChain) == 0 {
		t.Errorf("reuse must persist the chain: mda_verified=%v chain_len=%d", rec.MDAVerified, len(rec.MDACertChain))
	}
}

// TestAttachCachedMDAProof_ExpiredChainNotReused proves the time dimension: an
// expired cached chain fails local re-verification, so reuse is declined and a
// fresh attestation is requested instead of trusting a stale cert. (Apple uses a
// freshness model rather than a fixed expiry; this is the relying-party staleness
// check.)
func TestAttachCachedMDAProof_ExpiredChainNotReused(t *testing.T) {
	const serial, sePub = "SERIAL-EXP", "se-pub-exp"
	seHash := sha256.Sum256([]byte(sePub))
	// Leaf already expired.
	chain, root := mintMDALeafChainExp(t, serial, seHash[:], time.Now().Add(-time.Minute))
	defer attestation.OverrideRootCAForTest(root)()

	logger := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	reg := registry.New(logger)
	srv := &Server{registry: reg, logger: logger}
	p := reg.Register("p", nil, &protocol.RegisterMessage{Type: protocol.TypeRegister, Backend: "mlx-swift"})
	p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: serial, PublicKey: sePub})
	chainJSON, _ := json.Marshal(chain)
	p.StageMDAChainFromJSON(chainJSON)
	p.SetAttested(true, registry.TrustHardware)

	if srv.attachCachedMDAProof("p", p, *p.GetAttestationResult()) {
		t.Fatal("expected an expired cached chain NOT to be reused")
	}
	if mdaVerified(p) {
		t.Error("MDAVerified must stay false when the cached chain is expired")
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
