package attestation

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

// createTestMDACert creates a self-signed test certificate with custom MDA OIDs.
func createTestMDACert(t *testing.T, sipEnabled, secureBootEnabled, kextsAllowed bool) ([]byte, *x509.Certificate) {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	// Encode boolean values as ASN.1
	sipBytes, _ := asn1.Marshal(sipEnabled)
	bootBytes, _ := asn1.Marshal(secureBootEnabled)
	kextBytes, _ := asn1.Marshal(kextsAllowed)

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   "Test Device",
			SerialNumber: "C02XL3FHJG5J",
		},
		NotBefore: time.Now().Add(-1 * time.Hour),
		NotAfter:  time.Now().Add(24 * time.Hour),
		KeyUsage:  x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{
			{
				Id:    OIDSIPStatus,
				Value: sipBytes,
			},
			{
				Id:    OIDSecureBootStatus,
				Value: bootBytes,
			},
			{
				Id:    OIDKextStatus,
				Value: kextBytes,
			},
		},
		IsCA: true, // self-signed for testing
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &privKey.PublicKey, privKey)
	if err != nil {
		t.Fatal(err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: certDER,
	})

	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		t.Fatal(err)
	}

	return certPEM, cert
}

// createTestMDACertChain creates a CA + leaf certificate chain with MDA OIDs.
//
//nolint:nonamedreturns // named returns used internally for progressive PEM construction
func createTestMDACertChain(t *testing.T, sipEnabled, secureBootEnabled, kextsAllowed bool) (chainPEM []byte, rootCert *x509.Certificate) {
	t.Helper()

	// Generate CA key and certificate
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   "Apple Enterprise Attestation Root CA (Test)",
			Organization: []string{"Apple Inc."},
		},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}

	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}

	rootCert, err = x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}

	// Generate leaf key and certificate signed by CA
	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	sipBytes, _ := asn1.Marshal(sipEnabled)
	bootBytes, _ := asn1.Marshal(secureBootEnabled)
	kextBytes, _ := asn1.Marshal(kextsAllowed)

	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			CommonName:   "Test Device Leaf",
			SerialNumber: "C02XL3FHJG5J",
		},
		NotBefore: time.Now().Add(-1 * time.Hour),
		NotAfter:  time.Now().Add(24 * time.Hour),
		KeyUsage:  x509.KeyUsageDigitalSignature,
		ExtraExtensions: []pkix.Extension{
			{Id: OIDSIPStatus, Value: sipBytes},
			{Id: OIDSecureBootStatus, Value: bootBytes},
			{Id: OIDKextStatus, Value: kextBytes},
		},
	}

	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, rootCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}

	// Build PEM chain: leaf first, then CA
	leafPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})
	chainPEM = append(chainPEM, leafPEM...)

	return chainPEM, rootCert
}

func TestVerifyMDACertChainSelfSigned(t *testing.T) {
	certPEM, cert := createTestMDACert(t, true, true, false)

	result, err := VerifyMDACertChain(certPEM, cert)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !result.Valid {
		t.Fatalf("expected valid result, got error: %s", result.Error)
	}

	if !result.SIPEnabled {
		t.Error("expected SIPEnabled = true")
	}
	if !result.SecureBootEnabled {
		t.Error("expected SecureBootEnabled = true")
	}
	if result.ThirdPartyKexts {
		t.Error("expected ThirdPartyKexts = false")
	}
	if result.DeviceSerial != "C02XL3FHJG5J" {
		t.Errorf("device serial = %q, want C02XL3FHJG5J", result.DeviceSerial)
	}
}

func TestVerifyMDACertChainWithCA(t *testing.T) {
	chainPEM, rootCert := createTestMDACertChain(t, true, true, false)

	result, err := VerifyMDACertChain(chainPEM, rootCert)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !result.Valid {
		t.Fatalf("expected valid result, got error: %s", result.Error)
	}

	if !result.SIPEnabled {
		t.Error("expected SIPEnabled = true")
	}
	if !result.SecureBootEnabled {
		t.Error("expected SecureBootEnabled = true")
	}
}

func TestVerifyMDACertChainWrongRoot(t *testing.T) {
	chainPEM, _ := createTestMDACertChain(t, true, true, false)

	// Use a different root CA
	wrongKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	wrongTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(99),
		Subject: pkix.Name{
			CommonName: "Wrong Root CA",
		},
		NotBefore:             time.Now().Add(-1 * time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	wrongDER, _ := x509.CreateCertificate(rand.Reader, wrongTemplate, wrongTemplate, &wrongKey.PublicKey, wrongKey)
	wrongCert, _ := x509.ParseCertificate(wrongDER)

	result, err := VerifyMDACertChain(chainPEM, wrongCert)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Valid {
		t.Fatal("expected invalid result with wrong root CA")
	}
	if result.Error == "" {
		t.Error("expected non-empty error message")
	}
}

func TestVerifyMDACertChainNilRoot(t *testing.T) {
	// Without a root CA, the function should still parse OIDs but skip chain verification.
	certPEM, _ := createTestMDACert(t, false, true, true)

	result, err := VerifyMDACertChain(certPEM, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !result.Valid {
		t.Fatalf("expected valid result without root CA, got error: %s", result.Error)
	}

	if result.SIPEnabled {
		t.Error("expected SIPEnabled = false")
	}
	if !result.SecureBootEnabled {
		t.Error("expected SecureBootEnabled = true")
	}
	if !result.ThirdPartyKexts {
		t.Error("expected ThirdPartyKexts = true")
	}
}

func TestVerifyMDACertChainEmptyPEM(t *testing.T) {
	_, err := VerifyMDACertChain([]byte{}, nil)
	if err == nil {
		t.Fatal("expected error for empty PEM")
	}
}

func TestVerifyMDACertChainInvalidPEM(t *testing.T) {
	_, err := VerifyMDACertChain([]byte("not a pem"), nil)
	if err == nil {
		t.Fatal("expected error for invalid PEM")
	}
}

func TestParseBoolOID(t *testing.T) {
	trueBytes, _ := asn1.Marshal(true)
	falseBytes, _ := asn1.Marshal(false)

	if !parseBoolOID(trueBytes) {
		t.Error("expected true for ASN.1 TRUE")
	}
	if parseBoolOID(falseBytes) {
		t.Error("expected false for ASN.1 FALSE")
	}

	// Test raw byte fallback
	if !parseBoolOID([]byte{0xFF}) {
		t.Error("expected true for raw 0xFF")
	}
	if parseBoolOID([]byte{0x00}) {
		t.Error("expected false for raw 0x00")
	}

	// Test empty data
	if parseBoolOID([]byte{}) {
		t.Error("expected false for empty data")
	}
}

func TestOIDConstants(t *testing.T) {
	// Verify OID values match Apple's documented OIDs.
	expectedSIP := asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 1}
	expectedBoot := asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 2}
	expectedKext := asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 3}

	if !OIDSIPStatus.Equal(expectedSIP) {
		t.Errorf("OIDSIPStatus = %v, want %v", OIDSIPStatus, expectedSIP)
	}
	if !OIDSecureBootStatus.Equal(expectedBoot) {
		t.Errorf("OIDSecureBootStatus = %v, want %v", OIDSecureBootStatus, expectedBoot)
	}
	if !OIDKextStatus.Equal(expectedKext) {
		t.Errorf("OIDKextStatus = %v, want %v", OIDKextStatus, expectedKext)
	}
}
