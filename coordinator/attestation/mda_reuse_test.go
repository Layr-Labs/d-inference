package attestation

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"math/big"
	"testing"
	"time"
)

// mintDevicePropertiesChain builds a DER cert chain (leaf signed by a test CA)
// carrying the DevicePropertiesAttestation OIDs: device serial, UDID, and the
// freshness code (the SHA-256 of the SE public key the attestation was requested
// with). It returns the single-cert DER chain (leaf first) and the test CA so a
// caller can install it via OverrideRootCAForTest.
func mintDevicePropertiesChain(t *testing.T, serial, udid string, freshness []byte, notAfter time.Time) (chainDER [][]byte, root *x509.Certificate) {
	t.Helper()

	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	caTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Apple Enterprise Attestation Root CA (Test)"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
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

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	serialBytes, _ := asn1.Marshal(serial)
	udidBytes, _ := asn1.Marshal(udid)
	freshBytes, _ := asn1.Marshal(freshness) // OCTET STRING wrapping the raw hash

	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "Test Device Leaf"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{
			{Id: OIDDeviceSerialNumber, Value: serialBytes},
			{Id: OIDDeviceUDID, Value: udidBytes},
			{Id: OIDFreshnessCode, Value: freshBytes},
		},
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTmpl, root, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	return [][]byte{leafDER}, root
}

// TestVerifyMDADeviceAttestation_DevicePropertiesPath verifies the
// DevicePropertiesAttestation (DeviceInformation) path end-to-end against a
// test root: the chain validates, and the device serial/UDID/freshness OIDs are
// extracted. The freshness code must equal the raw SE-key hash so the caller can
// re-bind the proof to a specific machine.
func TestVerifyMDADeviceAttestation_DevicePropertiesPath(t *testing.T) {
	seHash := sha256.Sum256([]byte("se-public-key"))
	chain, root := mintDevicePropertiesChain(t, "C02XL3FHJG5J", "UDID-1234", seHash[:], time.Now().Add(24*time.Hour))

	restore := OverrideRootCAForTest(root)
	defer restore()

	res, err := VerifyMDADeviceAttestation(chain)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !res.Valid {
		t.Fatalf("expected valid, got error: %s", res.Error)
	}
	if res.DeviceSerial != "C02XL3FHJG5J" {
		t.Errorf("serial = %q, want C02XL3FHJG5J", res.DeviceSerial)
	}
	if res.DeviceUDID != "UDID-1234" {
		t.Errorf("udid = %q, want UDID-1234", res.DeviceUDID)
	}
	if string(res.FreshnessCode) != string(seHash[:]) {
		t.Errorf("freshness code does not match SE key hash")
	}
}

// TestVerifyMDADeviceAttestation_ExpiredLeafRejected confirms an expired cached
// chain is rejected by re-verification (so the reuse path falls back to a fresh
// request instead of trusting a stale cert).
func TestVerifyMDADeviceAttestation_ExpiredLeafRejected(t *testing.T) {
	seHash := sha256.Sum256([]byte("se-public-key"))
	chain, root := mintDevicePropertiesChain(t, "SERIAL", "UDID", seHash[:], time.Now().Add(-time.Minute))

	restore := OverrideRootCAForTest(root)
	defer restore()

	res, err := VerifyMDADeviceAttestation(chain)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Valid {
		t.Fatal("expected invalid result for an expired leaf cert")
	}
}

// TestVerifyMDADeviceAttestation_WrongRootRejected confirms a chain not signed by
// the active root fails — i.e. production still requires Apple's pinned root.
func TestVerifyMDADeviceAttestation_WrongRootRejected(t *testing.T) {
	seHash := sha256.Sum256([]byte("k"))
	chain, _ := mintDevicePropertiesChain(t, "SERIAL", "UDID", seHash[:], time.Now().Add(time.Hour))
	// Do NOT install the minting CA as the verify root — the default Apple root is
	// in effect, so the test chain must fail to verify.
	res, err := VerifyMDADeviceAttestation(chain)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.Valid {
		t.Fatal("expected invalid result when chain is not signed by the active root CA")
	}
}

// TestOverrideRootCAForTest_Restores ensures the test seam restores the real
// Apple root so it cannot leak across tests.
func TestOverrideRootCAForTest_Restores(t *testing.T) {
	orig := currentVerifyRoot()
	if orig != appleEnterpriseAttestationRootCA {
		t.Fatal("default verify root should be the embedded Apple root")
	}
	other := &x509.Certificate{}
	restore := OverrideRootCAForTest(other)
	if currentVerifyRoot() != other {
		t.Fatal("override did not take effect")
	}
	restore()
	if currentVerifyRoot() != appleEnterpriseAttestationRootCA {
		t.Fatal("restore did not return the embedded Apple root")
	}
}
