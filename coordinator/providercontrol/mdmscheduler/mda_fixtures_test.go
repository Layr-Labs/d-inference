package mdmscheduler

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"math/big"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
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
