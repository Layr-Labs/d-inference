package attestation

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/hex"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

// Real extension payloads captured from a live Apple Enterprise Attestation
// leaf cert (api.darkbloom.dev/v1/providers/attestation, 97/97 certs uniform):
//
//	.13.1 (SIP)        = 02 01 00            — DER INTEGER 0 (SIP fully ON)
//	.13.2 (SecureBoot) = "Full Security"     — RAW ASCII, no ASN.1 wrapper
//	.13.3 (kexts)      = 02 01 00            — DER INTEGER 0 (no 3rd-party kexts)
//
// These bytes are the regression anchor for the decode fix (issue #302 Gap 2):
// the old parseBoolOID read DER INTEGER 0 as last-byte!=0 → false, INVERTING
// the SIP bit, and read every .13.2 boot level (ending in 'y') as true.
var (
	liveSIPOn      = mustHex("020100")
	liveSIPOff     = mustHex("020101") // Apple: "1 indicates disabled"
	liveBootFull   = []byte("Full Security")
	liveKextsNone  = mustHex("020100")
	liveKextsSome  = mustHex("020101")
	liveBootReduce = []byte("Reduced Security")
	liveBootPerm   = []byte("Permissive Security")
)

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// mdaSecurityExtensions builds the three 100.8.13.* extensions in the REAL
// formats live Apple certs use (DER INTEGER / raw string).
func mdaSecurityExtensions(sip, kext []byte, boot []byte) []pkix.Extension {
	return []pkix.Extension{
		{Id: OIDSIPStatus, Value: sip},
		{Id: OIDSecureBootStatus, Value: boot},
		{Id: OIDKextStatus, Value: kext},
	}
}

// createTestMDACertWithExtensions creates a self-signed test certificate
// carrying the given extensions verbatim.
func createTestMDACertWithExtensions(t *testing.T, exts []pkix.Extension) ([]byte, *x509.Certificate) {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   "Test Device",
			SerialNumber: "C02XL3FHJG5J",
		},
		NotBefore:       time.Now().Add(-1 * time.Hour),
		NotAfter:        time.Now().Add(24 * time.Hour),
		KeyUsage:        x509.KeyUsageDigitalSignature,
		ExtraExtensions: exts,
		IsCA:            true, // self-signed for testing
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &privKey.PublicKey, privKey)
	if err != nil {
		t.Fatal(err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})
	cert, err := x509.ParseCertificate(certDER)
	if err != nil {
		t.Fatal(err)
	}
	return certPEM, cert
}

// createTestMDACert creates a self-signed test certificate with the security
// OIDs encoded the way real Apple certs encode them.
func createTestMDACert(t *testing.T, sip, kext []byte, boot []byte) ([]byte, *x509.Certificate) {
	t.Helper()
	return createTestMDACertWithExtensions(t, mdaSecurityExtensions(sip, kext, boot))
}

// createTestMDACertChain creates a CA + leaf certificate chain with MDA OIDs.
func createTestMDACertChain(t *testing.T, sip, kext []byte, boot []byte) (chainPEM []byte, rootCert *x509.Certificate) {
	t.Helper()

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

	leafKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			CommonName:   "Test Device Leaf",
			SerialNumber: "C02XL3FHJG5J",
		},
		NotBefore:       time.Now().Add(-1 * time.Hour),
		NotAfter:        time.Now().Add(24 * time.Hour),
		KeyUsage:        x509.KeyUsageDigitalSignature,
		ExtraExtensions: mdaSecurityExtensions(sip, kext, boot),
	}

	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, rootCert, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}

	chainPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})
	return chainPEM, rootCert
}

// TestMDADecodePinnedLiveBytes is the issue #302 Gap 2 regression anchor: the
// EXACT bytes live Apple certs carry must decode to SIP-on / Full-Security /
// no-kexts. The old parseBoolOID decode INVERTED the SIP bit (DER INTEGER 0 →
// false) and read every boot level as true — this test fails on that decode.
func TestMDADecodePinnedLiveBytes(t *testing.T) {
	certPEM, cert := createTestMDACert(t, liveSIPOn, liveKextsNone, liveBootFull)

	result, err := VerifyMDACertChain(certPEM, cert)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.Valid {
		t.Fatalf("expected valid result, got error: %s", result.Error)
	}

	if !result.SIPEnabled {
		t.Error("DER INTEGER 0 (csr fully enabled) must decode SIPEnabled = true — the old bool fallback inverted this")
	}
	if !result.SecureBootEnabled {
		t.Error(`raw "Full Security" must decode SecureBootEnabled = true`)
	}
	if result.BootState != "Full Security" {
		t.Errorf("BootState = %q, want \"Full Security\"", result.BootState)
	}
	if result.ThirdPartyKexts {
		t.Error("DER INTEGER 0 must decode ThirdPartyKexts = false")
	}
	if result.DeviceSerial != "C02XL3FHJG5J" {
		t.Errorf("device serial = %q, want C02XL3FHJG5J", result.DeviceSerial)
	}
	if result.LeafNotBefore.IsZero() {
		t.Error("LeafNotBefore must be populated from the leaf certificate")
	}
}

// TestMDADecodeWeakenedStates: a SIP-disabled or non-Full-Security cert must
// decode as NOT secure. The old decode read "Permissive Security" (and every
// other boot level) as SecureBootEnabled = true.
func TestMDADecodeWeakenedStates(t *testing.T) {
	cases := []struct {
		name     string
		sip      []byte
		boot     []byte
		kext     []byte
		wantSIP  bool
		wantBoot bool
		wantKext bool
	}{
		{"sip disabled (INTEGER 1)", liveSIPOff, liveBootFull, liveKextsNone, false, true, false},
		{"reduced security", liveSIPOn, liveBootReduce, liveKextsNone, true, false, false},
		{"permissive security", liveSIPOn, liveBootPerm, liveKextsNone, true, false, false},
		{"kexts allowed (INTEGER 1)", liveSIPOn, liveBootFull, liveKextsSome, true, true, true},
		{"sip csr bitmask nonzero", mustHex("020177"), liveBootFull, liveKextsNone, false, true, false},
		{"sip unparseable garbage fails closed", []byte("true"), liveBootFull, liveKextsNone, false, true, false},
		{"kexts unparseable fails closed (treated as allowed)", liveSIPOn, liveBootFull, []byte{0xff, 0xfe}, true, true, true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			certPEM, cert := createTestMDACert(t, tc.sip, tc.kext, tc.boot)
			result, err := VerifyMDACertChain(certPEM, cert)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if result.SIPEnabled != tc.wantSIP {
				t.Errorf("SIPEnabled = %v, want %v", result.SIPEnabled, tc.wantSIP)
			}
			if result.SecureBootEnabled != tc.wantBoot {
				t.Errorf("SecureBootEnabled = %v, want %v", result.SecureBootEnabled, tc.wantBoot)
			}
			if result.ThirdPartyKexts != tc.wantKext {
				t.Errorf("ThirdPartyKexts = %v, want %v", result.ThirdPartyKexts, tc.wantKext)
			}
		})
	}
}

// A DER-wrapped UTF8String boot state must also decode (defensive: Apple's
// encoding of .13.2 is undocumented; live certs use raw bytes).
func TestMDADecodeDERWrappedBootState(t *testing.T) {
	wrapped, err := asn1.Marshal("Full Security")
	if err != nil {
		t.Fatal(err)
	}
	certPEM, cert := createTestMDACert(t, liveSIPOn, liveKextsNone, wrapped)
	result, err := VerifyMDACertChain(certPEM, cert)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !result.SecureBootEnabled {
		t.Error("DER-wrapped \"Full Security\" must decode SecureBootEnabled = true")
	}
}

// Absent 13.x extensions must fail closed: no SIP/SecureBoot claims.
func TestMDADecodeAbsentExtensionsFailClosed(t *testing.T) {
	certPEM, cert := createTestMDACertWithExtensions(t, nil)
	result, err := VerifyMDACertChain(certPEM, cert)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.SIPEnabled {
		t.Error("absent SIP extension must read SIPEnabled = false")
	}
	if result.SecureBootEnabled {
		t.Error("absent SecureBoot extension must read SecureBootEnabled = false")
	}
	// An ABSENT .13.3 kext OID must fail closed to ThirdPartyKexts = true (the
	// case never runs, so the struct default must be the unsafe value) — otherwise
	// a cert that drops the OID slips past the evaluateMDA kext gate.
	if !result.ThirdPartyKexts {
		t.Error("absent kext extension must fail closed: ThirdPartyKexts = true")
	}
}

func TestVerifyMDACertChainWithCA(t *testing.T) {
	chainPEM, rootCert := createTestMDACertChain(t, liveSIPOn, liveKextsNone, liveBootFull)

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
	chainPEM, _ := createTestMDACertChain(t, liveSIPOn, liveKextsNone, liveBootFull)

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
	// Without a root CA, the function should still parse OIDs but skip chain
	// verification. SIP disabled + kexts allowed must decode as such.
	certPEM, _ := createTestMDACert(t, liveSIPOff, liveKextsSome, liveBootFull)

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

func TestParseIntOID(t *testing.T) {
	cases := []struct {
		name   string
		data   []byte
		want   int64
		wantOK bool
	}{
		{"DER INTEGER 0 (live SIP-on bytes)", mustHex("020100"), 0, true},
		{"DER INTEGER 1", mustHex("020101"), 1, true},
		{"DER INTEGER 0x77 (csr bitmask)", mustHex("020177"), 0x77, true},
		{"ASCII digits fallback", []byte("0"), 0, true},
		{"ASCII nonzero", []byte("23"), 23, true},
		{"raw 0xFF is NOT an integer", []byte{0xff}, 0, false},
		{"ASN.1 BOOLEAN true is NOT an integer", mustHex("0101ff"), 0, false},
		{"text is NOT an integer", []byte("true"), 0, false},
		{"empty", nil, 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseIntOID(tc.data)
			if ok != tc.wantOK || (ok && got != tc.want) {
				t.Errorf("parseIntOID(%x) = (%d, %v), want (%d, %v)", tc.data, got, ok, tc.want, tc.wantOK)
			}
		})
	}
}

// TestUnwrapFreshnessCode: live certs carry the nonce RAW; a raw 32-byte value
// must come back verbatim even when its leading bytes happen to parse as some
// ASN.1 TLV (the old blind Unmarshal sliced such nonces to garbage).
func TestUnwrapFreshnessCode(t *testing.T) {
	// The live cert's FreshnessCode begins 0x59 0x12 — which "parses" as an
	// APPLICATION-class TLV of length 18 and used to be silently truncated.
	live := mustHex("591278b7ed2c158d85ebca48d050e4a8cc05b68b4e8140e15fbfcbc5276dde9e")
	if got := unwrapFreshnessCode(live); !bytes.Equal(got, live) {
		t.Errorf("raw live nonce mangled: got %x (len %d), want full 32 bytes", got, len(got))
	}

	// A proper DER OCTET STRING wrap is unwrapped.
	inner := bytes.Repeat([]byte{0xAB}, 32)
	wrapped, err := asn1.Marshal(inner)
	if err != nil {
		t.Fatal(err)
	}
	if got := unwrapFreshnessCode(wrapped); !bytes.Equal(got, inner) {
		t.Errorf("DER-wrapped nonce not unwrapped: got %x", got)
	}

	// A raw nonce that merely STARTS with 0x04 but isn't a whole-value OCTET
	// STRING stays raw.
	tricky := append([]byte{0x04, 0xFF}, bytes.Repeat([]byte{0x01}, 30)...)
	if got := unwrapFreshnessCode(tricky); !bytes.Equal(got, tricky) {
		t.Errorf("raw 0x04-leading nonce mangled: got %x", got)
	}

	if got := unwrapFreshnessCode(nil); len(got) != 0 {
		t.Errorf("empty input: got %x", got)
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
