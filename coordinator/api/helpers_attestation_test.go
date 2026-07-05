package api

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

const knownGoodBinaryHashForTest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

type ecdsaSigHelper struct {
	R, S *big.Int
}

var testAttestationChallengeKeys sync.Map

func registerTestChallengeSigner(encryptionKey string, privKey *ecdsa.PrivateKey) {
	if encryptionKey == "" || privKey == nil {
		return
	}
	testAttestationChallengeKeys.Store(encryptionKey, privKey)
}

func testChallengeSignature(nonce, timestamp, encryptionKey string) string {
	if rawKey, ok := testAttestationChallengeKeys.Load(encryptionKey); ok {
		if privKey, ok := rawKey.(*ecdsa.PrivateKey); ok && privKey != nil {
			hash := sha256.Sum256([]byte(nonce + timestamp))
			r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
			if err == nil {
				if sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s}); err == nil {
					return base64.StdEncoding.EncodeToString(sigDER)
				}
			}
		}
	}
	return "dGVzdHNpZ25hdHVyZQ=="
}

// testStatusSignature signs the canonical status payload with the SE private key
// registered for encryptionKey, so verifyChallengeResponse treats the status
// fields as cryptographically bound (statusFieldsTrusted=true) — required to reach
// the trust-reuse fast-skip in tests.
func testStatusSignature(t *testing.T, in attestation.StatusCanonicalInput, encryptionKey string) string {
	t.Helper()
	rawKey, ok := testAttestationChallengeKeys.Load(encryptionKey)
	if !ok {
		t.Fatalf("no challenge signer registered for %q", encryptionKey)
	}
	privKey, ok := rawKey.(*ecdsa.PrivateKey)
	if !ok || privKey == nil {
		t.Fatalf("invalid challenge signer for %q", encryptionKey)
	}
	canonical, err := attestation.BuildStatusCanonical(in)
	if err != nil {
		t.Fatalf("BuildStatusCanonical: %v", err)
	}
	hash := sha256.Sum256(canonical)
	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
	if err != nil {
		t.Fatalf("sign status: %v", err)
	}
	sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s})
	if err != nil {
		t.Fatalf("marshal status sig: %v", err)
	}
	return base64.StdEncoding.EncodeToString(sigDER)
}

func createTestAttestationJSON(t *testing.T, encryptionKey string) json.RawMessage {
	return buildTestAttestationJSON(t, encryptionKey, "", "")
}

func createTestAttestationJSONWithBinaryHash(t *testing.T, encryptionKey, binaryHash string) json.RawMessage {
	return buildTestAttestationJSON(t, encryptionKey, binaryHash, "")
}

// createTestAttestationJSONWithSerial creates a signed attestation blob with a
// specific serial number, for provider-deduplication tests.
func createTestAttestationJSONWithSerial(t *testing.T, serial, encryptionKey string) json.RawMessage {
	return buildTestAttestationJSON(t, encryptionKey, "", serial)
}

// buildTestAttestationJSON builds and ECDSA-signs a Secure Enclave-shaped
// attestation blob. Optional fields (binaryHash, serialNumber) are added only
// when non-empty. When encryptionKey is set, the generated P-256 key is
// registered as its challenge signer so subsequent challenge responses verify.
func buildTestAttestationJSON(t *testing.T, encryptionKey, binaryHash, serial string) json.RawMessage {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	// Marshal public key as uncompressed point (65 bytes: 0x04 || X || Y)
	xBytes := privKey.X.Bytes()
	yBytes := privKey.Y.Bytes()
	raw := make([]byte, 65)
	raw[0] = 0x04
	copy(raw[1+32-len(xBytes):33], xBytes)
	copy(raw[33+32-len(yBytes):65], yBytes)
	pubKeyB64 := base64.StdEncoding.EncodeToString(raw)

	blobMap := map[string]interface{}{
		"authenticatedRootEnabled": true,
		"chipName":                 "Apple M3 Max",
		"hardwareModel":            "Mac15,8",
		"osVersion":                "15.3.0",
		"publicKey":                pubKeyB64,
		"rdmaDisabled":             true,
		"secureBootEnabled":        true,
		"secureEnclaveAvailable":   true,
		"sipEnabled":               true,
		"timestamp":                time.Now().UTC().Format(time.RFC3339),
	}
	if encryptionKey != "" {
		blobMap["encryptionPublicKey"] = encryptionKey
		registerTestChallengeSigner(encryptionKey, privKey)
	}
	if binaryHash != "" {
		blobMap["binaryHash"] = binaryHash
	}
	if serial != "" {
		blobMap["serialNumber"] = serial
	}

	blobJSON, err := json.Marshal(blobMap)
	if err != nil {
		t.Fatal(err)
	}

	hash := sha256.Sum256(blobJSON)
	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}

	signed := map[string]interface{}{
		"attestation": json.RawMessage(blobJSON),
		"signature":   base64.StdEncoding.EncodeToString(sigDER),
	}

	signedJSON, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}

	return signedJSON
}
