package attestation_test

import (
	"encoding/asn1"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/attestation"

	attestationwire "github.com/eigeninference/d-inference/coordinator/internal/attestation/wire"
)

const testDeviceSerial = "TEST-DEVICE-SERIAL"

func TestParseBoolOID(t *testing.T) {
	trueBytes, _ := asn1.Marshal(true)
	falseBytes, _ := asn1.Marshal(false)

	if !attestationwire.ParseBoolOID(trueBytes) {
		t.Error("expected true for ASN.1 TRUE")
	}
	if attestationwire.ParseBoolOID(falseBytes) {
		t.Error("expected false for ASN.1 FALSE")
	}

	// Test raw byte fallback
	if !attestationwire.ParseBoolOID([]byte{0xFF}) {
		t.Error("expected true for raw 0xFF")
	}
	if attestationwire.ParseBoolOID([]byte{0x00}) {
		t.Error("expected false for raw 0x00")
	}

	// Test empty data
	if attestationwire.ParseBoolOID([]byte{}) {
		t.Error("expected false for empty data")
	}
}

func TestOIDConstants(t *testing.T) {
	// Verify OID values match Apple's documented OIDs.
	expectedSIP := asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 1}
	expectedBoot := asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 2}
	expectedKext := asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 8, 13, 3}

	if !production.OIDSIPStatus.Equal(expectedSIP) {
		t.Errorf("OIDSIPStatus = %v, want %v", production.OIDSIPStatus, expectedSIP)
	}
	if !production.OIDSecureBootStatus.Equal(expectedBoot) {
		t.Errorf("OIDSecureBootStatus = %v, want %v", production.OIDSecureBootStatus, expectedBoot)
	}
	if !production.OIDKextStatus.Equal(expectedKext) {
		t.Errorf("OIDKextStatus = %v, want %v", production.OIDKextStatus, expectedKext)
	}
}
