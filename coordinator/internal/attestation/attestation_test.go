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
		PublicKey:                base64.StdEncoding.EncodeToString(pubKeyBytes),
		Timestamp:                time.Now().UTC().Format(time.RFC3339),
		HardwareModel:            "Mac15,8",
		ChipName:                 "Apple M3 Max",
		OSVersion:                "15.3.0",
		SecureEnclaveAvailable:   true,
		SIPEnabled:               false, // SIP disabled
		SecureBootEnabled:        true,
		RDMADisabled:             true,
		AuthenticatedRootEnabled: true,
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
		PublicKey:                base64.StdEncoding.EncodeToString(pubKeyBytes),
		Timestamp:                time.Now().UTC().Format(time.RFC3339),
		HardwareModel:            "Mac15,8",
		ChipName:                 "Apple M3 Max",
		OSVersion:                "15.3.0",
		SecureEnclaveAvailable:   false, // no SE
		SIPEnabled:               true,
		SecureBootEnabled:        true,
		RDMADisabled:             true,
		AuthenticatedRootEnabled: true,
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
		ChipName:                 "Apple M3 Max",
		EncryptionPublicKey:      encKey,
		HardwareModel:            "Mac15,8",
		OSVersion:                "15.3.0",
		PublicKey:                base64.StdEncoding.EncodeToString(pubKeyBytes),
		RDMADisabled:             true,
		SecureBootEnabled:        true,
		SecureEnclaveAvailable:   true,
		SIPEnabled:               true,
		AuthenticatedRootEnabled: true,
		Timestamp:                time.Now().UTC().Format(time.RFC3339),
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

	parsed, err := ParseP256PublicKey(raw)
	if err != nil {
		t.Fatal(err)
	}

	if parsed.X.Cmp(privKey.X) != 0 || parsed.Y.Cmp(privKey.Y) != 0 {
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

	parsed, err := ParseP256PublicKey(rawXY)
	if err != nil {
		t.Fatal(err)
	}

	if parsed.X.Cmp(privKey.X) != 0 || parsed.Y.Cmp(privKey.Y) != 0 {
		t.Error("parsed key does not match original")
	}
}

// TestParseP256PublicKeyInvalid tests rejection of invalid key data.
func TestParseP256PublicKeyInvalid(t *testing.T) {
	_, err := ParseP256PublicKey([]byte("short"))
	if err == nil {
		t.Error("expected error for short key data")
	}

	// 65 bytes but not a valid curve point
	bad := make([]byte, 65)
	bad[0] = 0x04
	_, err = ParseP256PublicKey(bad)
	if err == nil {
		t.Error("expected error for invalid curve point")
	}
}

// ---------------------------------------------------------------------------
// VerifyChallengeSignature tests
// ---------------------------------------------------------------------------

// TestVerifyChallengeSignatureValid generates a real P-256 key pair, signs
// challenge data, and verifies it round-trips correctly.
func TestVerifyChallengeSignatureValid(t *testing.T) {
	// Generate a P-256 key pair (simulating Secure Enclave)
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	// Export public key as raw X||Y (64 bytes), base64-encoded
	xBytes := privKey.X.Bytes()
	yBytes := privKey.Y.Bytes()
	padded := make([]byte, 64)
	copy(padded[32-len(xBytes):32], xBytes)
	copy(padded[64-len(yBytes):64], yBytes)
	pubKeyB64 := base64.StdEncoding.EncodeToString(padded)

	// Sign challenge data: SHA-256(nonce + timestamp)
	challengeData := "test-nonce-1234567890" + "2026-04-12T00:00:00Z"
	hash := sha256.Sum256([]byte(challengeData))
	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
	if err != nil {
		t.Fatal(err)
	}

	// DER-encode the signature
	derSig, err := asn1.Marshal(ecdsaSig{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}
	sigB64 := base64.StdEncoding.EncodeToString(derSig)

	// Verify — should succeed
	if err := VerifyChallengeSignature(pubKeyB64, sigB64, challengeData); err != nil {
		t.Errorf("expected valid signature to verify, got: %v", err)
	}
}

// TestVerifyChallengeSignatureWrongData verifies that a valid signature
// fails verification when the challenge data doesn't match.
func TestVerifyChallengeSignatureWrongData(t *testing.T) {
	privKey, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	xBytes := privKey.X.Bytes()
	yBytes := privKey.Y.Bytes()
	padded := make([]byte, 64)
	copy(padded[32-len(xBytes):32], xBytes)
	copy(padded[64-len(yBytes):64], yBytes)
	pubKeyB64 := base64.StdEncoding.EncodeToString(padded)

	// Sign one message
	hash := sha256.Sum256([]byte("correct-data"))
	r, s, _ := ecdsa.Sign(rand.Reader, privKey, hash[:])
	derSig, _ := asn1.Marshal(ecdsaSig{R: r, S: s})
	sigB64 := base64.StdEncoding.EncodeToString(derSig)

	// Verify against different data — should fail
	if err := VerifyChallengeSignature(pubKeyB64, sigB64, "wrong-data"); err == nil {
		t.Error("expected verification to fail with wrong data")
	}
}

// TestVerifyChallengeSignatureWrongKey verifies that a valid signature
// fails verification against a different public key.
func TestVerifyChallengeSignatureWrongKey(t *testing.T) {
	privKey1, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	privKey2, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)

	// Use key2's public key
	xBytes := privKey2.X.Bytes()
	yBytes := privKey2.Y.Bytes()
	padded := make([]byte, 64)
	copy(padded[32-len(xBytes):32], xBytes)
	copy(padded[64-len(yBytes):64], yBytes)
	pubKeyB64 := base64.StdEncoding.EncodeToString(padded)

	// Sign with key1
	data := "challenge-nonce"
	hash := sha256.Sum256([]byte(data))
	r, s, _ := ecdsa.Sign(rand.Reader, privKey1, hash[:])
	derSig, _ := asn1.Marshal(ecdsaSig{R: r, S: s})
	sigB64 := base64.StdEncoding.EncodeToString(derSig)

	// Verify with key2 — should fail
	if err := VerifyChallengeSignature(pubKeyB64, sigB64, data); err == nil {
		t.Error("expected verification to fail with wrong key")
	}
}

// TestVerifyChallengeSignatureInvalidInputs tests error handling for
// malformed base64, invalid keys, and invalid signatures.
func TestVerifyChallengeSignatureInvalidInputs(t *testing.T) {
	tests := []struct {
		name   string
		pubKey string
		sig    string
		data   string
	}{
		{"invalid pubkey base64", "not-base64!!!", "dGVzdA==", "data"},
		{"invalid sig base64", "dGVzdA==", "not-base64!!!", "data"},
		{"pubkey too short", base64.StdEncoding.EncodeToString([]byte("short")), "dGVzdA==", "data"},
		{"sig not DER", base64.StdEncoding.EncodeToString(make([]byte, 64)), base64.StdEncoding.EncodeToString([]byte("not-der")), "data"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if err := VerifyChallengeSignature(tt.pubKey, tt.sig, tt.data); err == nil {
				t.Errorf("expected error for %s", tt.name)
			}
		})
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
		RDMADisabled:           true,
		SecureEnclaveAvailable: true,
		SIPEnabled:             true,
		SecureBootEnabled:      true,
	}

	data, err := marshalSortedJSON(blob)
	if err != nil {
		t.Fatal(err)
	}

	jsonStr := string(data)

	// Verify key ordering: chip < hardware < os < public < rdma < secureBoot < secureEnclave < sip < timestamp
	// (encryptionPublicKey is omitted when empty)
	keys := []string{
		"chipName", "hardwareModel", "osVersion", "publicKey", "rdmaDisabled",
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
		RDMADisabled:           true,
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
		"chipName", "encryptionPublicKey", "hardwareModel", "osVersion", "publicKey", "rdmaDisabled",
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
		PublicKey:                base64.StdEncoding.EncodeToString(pubKeyBytes),
		Timestamp:                time.Now().UTC().Format(time.RFC3339),
		HardwareModel:            "Mac15,8",
		ChipName:                 "Apple M3 Max",
		OSVersion:                "15.3.0",
		SecureEnclaveAvailable:   true,
		SIPEnabled:               true,
		SecureBootEnabled:        true,
		RDMADisabled:             true,
		AuthenticatedRootEnabled: true,
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
	xBytes := key.X.Bytes()
	yBytes := key.Y.Bytes()

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
