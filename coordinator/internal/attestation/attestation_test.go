package attestation

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

// TestVerifyValidAttestation creates a P-256 attestation in pure Go
// (simulating what the Swift Secure Enclave module produces) and
// verifies it through the same code path.
func TestVerifyValidAttestation(t *testing.T) {
	signed := createTestAttestation(t)

	result := Verify(signed)
	if !result.Valid {
		t.Fatalf("expected valid attestation, got error: %s", result.Error)
	}
	if result.HardwareModel != "Mac15,8" {
		t.Errorf("expected Mac15,8, got %s", result.HardwareModel)
	}
	if result.ChipName != "Apple M3 Max" {
		t.Errorf("expected Apple M3 Max, got %s", result.ChipName)
	}
	if !result.SecureEnclaveAvailable {
		t.Error("expected SecureEnclaveAvailable=true")
	}
	if !result.SIPEnabled {
		t.Error("expected SIPEnabled=true")
	}
}

// TestVerifyTamperedAttestation modifies the attestation after signing
// and expects verification to fail.
func TestVerifyTamperedAttestation(t *testing.T) {
	signed := createTestAttestation(t)

	// Tamper with the hardware model and clear raw bytes to force re-encoding
	signed.Attestation.HardwareModel = "FakeHardware"
	signed.AttestationRaw = nil

	result := Verify(signed)
	if result.Valid {
		t.Fatal("expected invalid attestation after tampering")
	}
	if result.Error != "signature verification failed" {
		t.Errorf("unexpected error: %s", result.Error)
	}
}

// TestVerifyBadSignature uses a completely invalid signature.
func TestVerifyBadSignature(t *testing.T) {
	signed := createTestAttestation(t)
	signed.Signature = base64.StdEncoding.EncodeToString([]byte("not a real signature"))

	result := Verify(signed)
	if result.Valid {
		t.Fatal("expected invalid attestation with bad signature")
	}
}

// TestVerifyBadPublicKey uses an invalid public key.
func TestVerifyBadPublicKey(t *testing.T) {
	signed := createTestAttestation(t)
	signed.Attestation.PublicKey = base64.StdEncoding.EncodeToString([]byte("short"))

	result := Verify(signed)
	if result.Valid {
		t.Fatal("expected invalid attestation with bad public key")
	}
}

// TestVerifyMissingSIP checks that attestations with SIP disabled fail.
func TestVerifyMissingSIP(t *testing.T) {
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pubKeyBytes := marshalUncompressedP256(privKey)

	blob := AttestationBlob{
		PublicKey:              base64.StdEncoding.EncodeToString(pubKeyBytes),
		Timestamp:              time.Now().UTC().Format(time.RFC3339),
		HardwareModel:          "Mac15,8",
		ChipName:               "Apple M3 Max",
		OSVersion:              "15.3.0",
		SecureEnclaveAvailable: true,
		SIPEnabled:             false, // SIP disabled
		SecureBootEnabled:      true,
	}

	signed := signBlob(t, blob, privKey)
	result := Verify(signed)
	if result.Valid {
		t.Fatal("expected attestation to fail with SIP disabled")
	}
	if result.Error != "SIP not enabled" {
		t.Errorf("unexpected error: %s", result.Error)
	}
}

// TestVerifyMissingSecureEnclave checks that attestations without SE fail.
func TestVerifyMissingSecureEnclave(t *testing.T) {
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pubKeyBytes := marshalUncompressedP256(privKey)

	blob := AttestationBlob{
		PublicKey:              base64.StdEncoding.EncodeToString(pubKeyBytes),
		Timestamp:              time.Now().UTC().Format(time.RFC3339),
		HardwareModel:          "Mac15,8",
		ChipName:               "Apple M3 Max",
		OSVersion:              "15.3.0",
		SecureEnclaveAvailable: false, // no SE
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	signed := signBlob(t, blob, privKey)
	result := Verify(signed)
	if result.Valid {
		t.Fatal("expected attestation to fail without Secure Enclave")
	}
}

// TestVerifyJSON tests the JSON convenience wrapper.
func TestVerifyJSON(t *testing.T) {
	signed := createTestAttestation(t)

	jsonData, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}

	result, err := VerifyJSON(jsonData)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Valid {
		t.Fatalf("expected valid attestation, got error: %s", result.Error)
	}
}

// TestVerifyWithEncryptionKey tests attestation with an encryption public key.
func TestVerifyWithEncryptionKey(t *testing.T) {
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pubKeyBytes := marshalUncompressedP256(privKey)

	encKey := base64.StdEncoding.EncodeToString([]byte("fake-x25519-public-key-32bytes!!"))

	blob := AttestationBlob{
		ChipName:               "Apple M3 Max",
		EncryptionPublicKey:    encKey,
		HardwareModel:          "Mac15,8",
		OSVersion:              "15.3.0",
		PublicKey:              base64.StdEncoding.EncodeToString(pubKeyBytes),
		SecureBootEnabled:      true,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		Timestamp:              time.Now().UTC().Format(time.RFC3339),
	}

	signed := signBlob(t, blob, privKey)
	result := Verify(signed)
	if !result.Valid {
		t.Fatalf("expected valid attestation with encryption key, got error: %s", result.Error)
	}
	if result.EncryptionPublicKey != encKey {
		t.Errorf("encryption key = %q, want %q", result.EncryptionPublicKey, encKey)
	}
}

// TestCheckTimestamp verifies the timestamp freshness check.
func TestCheckTimestamp(t *testing.T) {
	result := VerificationResult{
		Valid:     true,
		Timestamp: time.Now().Add(-30 * time.Second),
	}

	if !CheckTimestamp(result, 1*time.Minute) {
		t.Error("expected 30s old attestation to pass 1m check")
	}
	if CheckTimestamp(result, 10*time.Second) {
		t.Error("expected 30s old attestation to fail 10s check")
	}
}

// TestParseP256PublicKeyUncompressed tests 65-byte uncompressed format.
func TestParseP256PublicKeyUncompressed(t *testing.T) {
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	raw := marshalUncompressedP256(privKey)
	if len(raw) != 65 {
		t.Fatalf("expected 65 bytes, got %d", len(raw))
	}

	parsed, err := parseP256PublicKey(raw)
	if err != nil {
		t.Fatal(err)
	}

	if parsed.X.Cmp(privKey.PublicKey.X) != 0 || parsed.Y.Cmp(privKey.PublicKey.Y) != 0 {
		t.Error("parsed key does not match original")
	}
}

// TestParseP256PublicKeyRawXY tests 64-byte raw X||Y format.
func TestParseP256PublicKeyRawXY(t *testing.T) {
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	raw := marshalUncompressedP256(privKey)
	// Strip the 0x04 prefix
	rawXY := raw[1:]
	if len(rawXY) != 64 {
		t.Fatalf("expected 64 bytes, got %d", len(rawXY))
	}

	parsed, err := parseP256PublicKey(rawXY)
	if err != nil {
		t.Fatal(err)
	}

	if parsed.X.Cmp(privKey.PublicKey.X) != 0 || parsed.Y.Cmp(privKey.PublicKey.Y) != 0 {
		t.Error("parsed key does not match original")
	}
}

// TestParseP256PublicKeyInvalid tests rejection of invalid key data.
func TestParseP256PublicKeyInvalid(t *testing.T) {
	_, err := parseP256PublicKey([]byte("short"))
	if err == nil {
		t.Error("expected error for short key data")
	}

	// 65 bytes but not a valid curve point
	bad := make([]byte, 65)
	bad[0] = 0x04
	_, err = parseP256PublicKey(bad)
	if err == nil {
		t.Error("expected error for invalid curve point")
	}
}

// TestMarshalSortedJSON checks that keys are alphabetically ordered.
func TestMarshalSortedJSON(t *testing.T) {
	blob := AttestationBlob{
		PublicKey:              "dGVzdA==",
		Timestamp:              "2025-01-01T00:00:00Z",
		HardwareModel:          "Mac15,8",
		ChipName:               "Apple M3 Max",
		OSVersion:              "15.3.0",
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	data, err := marshalSortedJSON(blob)
	if err != nil {
		t.Fatal(err)
	}

	jsonStr := string(data)

	// Verify key ordering: chip < hardware < os < public < secureBoot < secureEnclave < sip < timestamp
	// (encryptionPublicKey is omitted when empty)
	keys := []string{
		"chipName", "hardwareModel", "osVersion", "publicKey",
		"secureBootEnabled", "secureEnclaveAvailable", "sipEnabled", "timestamp",
	}
	lastIdx := -1
	for _, key := range keys {
		idx := findStringIndex(jsonStr, `"`+key+`"`)
		if idx < 0 {
			t.Errorf("key %q not found in JSON", key)
			continue
		}
		if idx <= lastIdx {
			t.Errorf("key %q is out of alphabetical order", key)
		}
		lastIdx = idx
	}

	// Verify that empty encryptionPublicKey is not included
	if findStringIndex(jsonStr, "encryptionPublicKey") >= 0 {
		t.Error("encryptionPublicKey should be omitted when empty")
	}
}

// TestMarshalSortedJSONWithEncryptionKey checks alphabetical order with encryption key.
func TestMarshalSortedJSONWithEncryptionKey(t *testing.T) {
	blob := AttestationBlob{
		PublicKey:              "dGVzdA==",
		EncryptionPublicKey:    "ZW5jcnlwdGlvbktleQ==",
		Timestamp:              "2025-01-01T00:00:00Z",
		HardwareModel:          "Mac15,8",
		ChipName:               "Apple M3 Max",
		OSVersion:              "15.3.0",
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	data, err := marshalSortedJSON(blob)
	if err != nil {
		t.Fatal(err)
	}

	jsonStr := string(data)

	// encryptionPublicKey sorts between chipName and hardwareModel
	keys := []string{
		"chipName", "encryptionPublicKey", "hardwareModel", "osVersion", "publicKey",
		"secureBootEnabled", "secureEnclaveAvailable", "sipEnabled", "timestamp",
	}
	lastIdx := -1
	for _, key := range keys {
		idx := findStringIndex(jsonStr, `"`+key+`"`)
		if idx < 0 {
			t.Errorf("key %q not found in JSON", key)
			continue
		}
		if idx <= lastIdx {
			t.Errorf("key %q is out of alphabetical order", key)
		}
		lastIdx = idx
	}
}

// --- helpers ---

func createTestAttestation(t *testing.T) SignedAttestation {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pubKeyBytes := marshalUncompressedP256(privKey)

	blob := AttestationBlob{
		PublicKey:              base64.StdEncoding.EncodeToString(pubKeyBytes),
		Timestamp:              time.Now().UTC().Format(time.RFC3339),
		HardwareModel:          "Mac15,8",
		ChipName:               "Apple M3 Max",
		OSVersion:              "15.3.0",
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	return signBlob(t, blob, privKey)
}

func signBlob(t *testing.T, blob AttestationBlob, privKey *ecdsa.PrivateKey) SignedAttestation {
	t.Helper()

	blobJSON, err := marshalSortedJSON(blob)
	if err != nil {
		t.Fatal(err)
	}

	hash := sha256.Sum256(blobJSON)

	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
	if err != nil {
		t.Fatal(err)
	}

	sigDER, err := asn1.Marshal(ecdsaSig{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}

	return SignedAttestation{
		Attestation:    blob,
		AttestationRaw: blobJSON,
		Signature:      base64.StdEncoding.EncodeToString(sigDER),
	}
}

func marshalUncompressedP256(key *ecdsa.PrivateKey) []byte {
	xBytes := key.PublicKey.X.Bytes()
	yBytes := key.PublicKey.Y.Bytes()

	// Pad to 32 bytes each
	raw := make([]byte, 65)
	raw[0] = 0x04
	copy(raw[1+32-len(xBytes):33], xBytes)
	copy(raw[33+32-len(yBytes):65], yBytes)

	return raw
}

func findStringIndex(s, substr string) int {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}
