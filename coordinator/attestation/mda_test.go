package attestation

import (
	"encoding/asn1"
	"testing"
)

const testDeviceSerial = "TEST-DEVICE-SERIAL"

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
