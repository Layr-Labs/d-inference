package e2e

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/nacl/box"
)

func TestGenerateSessionKeys(t *testing.T) {
	k1, err := GenerateSessionKeys()
	if err != nil {
		t.Fatalf("GenerateSessionKeys: %v", err)
	}
	k2, err := GenerateSessionKeys()
	if err != nil {
		t.Fatalf("GenerateSessionKeys (2): %v", err)
	}
	// Keys should be distinct (different ephemeral sessions).
	if k1.PublicKey == k2.PublicKey {
		t.Error("two session key pairs should have different public keys")
	}
	if k1.PrivateKey == k2.PrivateKey {
		t.Error("two session key pairs should have different private keys")
	}
	// Public and private should differ within the same pair.
	if k1.PublicKey == k1.PrivateKey {
		t.Error("public and private key should differ")
	}
}

func TestEncryptDecryptRoundtrip(t *testing.T) {
	// Simulate coordinator encrypting for a provider.
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := GenerateSessionKeys()

	plaintext := []byte(`{"model":"test","messages":[{"role":"user","content":"hello"}]}`)

	encrypted, err := Encrypt(plaintext, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// Provider decrypts using its private key and coordinator's ephemeral public.
	providerSession := &SessionKeys{PrivateKey: *providerPriv}
	providerSession.PublicKey = *providerPub
	// For decryption, the session's private key is the provider's private key.
	decrypted, err := Decrypt(encrypted, &SessionKeys{PrivateKey: *providerPriv})
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !bytes.Equal(plaintext, decrypted) {
		t.Errorf("plaintext mismatch: got %q, want %q", decrypted, plaintext)
	}
}

func TestEncryptDecryptWithPrivateKey(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := GenerateSessionKeys()

	plaintext := []byte("test payload for DecryptWithPrivateKey")
	encrypted, err := Encrypt(plaintext, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	decrypted, err := DecryptWithPrivateKey(encrypted, *providerPriv)
	if err != nil {
		t.Fatalf("DecryptWithPrivateKey: %v", err)
	}
	if !bytes.Equal(plaintext, decrypted) {
		t.Errorf("mismatch: got %q", decrypted)
	}
}

func TestDecryptWrongKeyFails(t *testing.T) {
	providerPub, _, _ := box.GenerateKey(rand.Reader)
	_, wrongPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := GenerateSessionKeys()

	encrypted, _ := Encrypt([]byte("secret"), *providerPub, session)

	_, err := DecryptWithPrivateKey(encrypted, *wrongPriv)
	if err == nil {
		t.Error("decryption with wrong key should fail")
	}
}

func TestEncryptionNonDeterministic(t *testing.T) {
	providerPub, _, _ := box.GenerateKey(rand.Reader)
	session, _ := GenerateSessionKeys()
	plaintext := []byte("same input")

	enc1, _ := Encrypt(plaintext, *providerPub, session)
	enc2, _ := Encrypt(plaintext, *providerPub, session)

	// Different nonces should produce different ciphertexts.
	if enc1.Ciphertext == enc2.Ciphertext {
		t.Error("two encryptions of same plaintext should produce different ciphertext (random nonce)")
	}
}

func TestDecryptTamperedCiphertext(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := GenerateSessionKeys()

	encrypted, _ := Encrypt([]byte("authentic message"), *providerPub, session)

	// Tamper with ciphertext.
	ct, _ := base64.StdEncoding.DecodeString(encrypted.Ciphertext)
	ct[len(ct)-1] ^= 0xFF // flip last byte
	encrypted.Ciphertext = base64.StdEncoding.EncodeToString(ct)

	_, err := DecryptWithPrivateKey(encrypted, *providerPriv)
	if err == nil {
		t.Error("decryption of tampered ciphertext should fail")
	}
}

func TestDecryptShortCiphertext(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		Ciphertext:         base64.StdEncoding.EncodeToString(make([]byte, 10)), // too short for nonce
	}
	_, err := DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("ciphertext shorter than 24-byte nonce should fail")
	}
}

func TestDecryptInvalidBase64Ciphertext(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		Ciphertext:         "not-valid-base64!!!",
	}
	_, err := DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("invalid base64 ciphertext should fail")
	}
}

func TestDecryptInvalidBase64PublicKey(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &EncryptedPayload{
		EphemeralPublicKey: "not-valid!!!",
		Ciphertext:         base64.StdEncoding.EncodeToString(make([]byte, 48)),
	}
	_, err := DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("invalid base64 public key should fail")
	}
}

func TestDecryptWrongLengthPublicKey(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(make([]byte, 16)), // 16 != 32
		Ciphertext:         base64.StdEncoding.EncodeToString(make([]byte, 48)),
	}
	_, err := DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("public key of wrong length should fail")
	}
	if !strings.Contains(err.Error(), "length") {
		t.Errorf("error should mention length, got: %v", err)
	}
}

func TestEncryptEmptyPlaintext(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := GenerateSessionKeys()

	encrypted, err := Encrypt([]byte{}, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt empty: %v", err)
	}

	decrypted, err := DecryptWithPrivateKey(encrypted, *providerPriv)
	if err != nil {
		t.Fatalf("Decrypt empty: %v", err)
	}
	if len(decrypted) != 0 {
		t.Errorf("expected empty plaintext, got %d bytes", len(decrypted))
	}
}

func TestEncryptLargePayload(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := GenerateSessionKeys()

	// 1 MB payload (large prompt).
	plaintext := make([]byte, 1024*1024)
	rand.Read(plaintext)

	encrypted, err := Encrypt(plaintext, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt large: %v", err)
	}

	decrypted, err := DecryptWithPrivateKey(encrypted, *providerPriv)
	if err != nil {
		t.Fatalf("Decrypt large: %v", err)
	}
	if !bytes.Equal(plaintext, decrypted) {
		t.Error("large payload mismatch after round-trip")
	}
}

func TestParsePublicKey(t *testing.T) {
	pub, _, _ := box.GenerateKey(rand.Reader)
	b64 := base64.StdEncoding.EncodeToString(pub[:])

	parsed, err := ParsePublicKey(b64)
	if err != nil {
		t.Fatalf("ParsePublicKey: %v", err)
	}
	if parsed != *pub {
		t.Error("parsed key doesn't match original")
	}
}

func TestParsePublicKeyInvalid(t *testing.T) {
	if _, err := ParsePublicKey("not-base64!!!"); err == nil {
		t.Error("invalid base64 should fail")
	}
	if _, err := ParsePublicKey(base64.StdEncoding.EncodeToString(make([]byte, 16))); err == nil {
		t.Error("wrong length should fail")
	}
	if _, err := ParsePublicKey(""); err == nil {
		t.Error("empty string should fail")
	}
}

func TestBidirectionalEncryption(t *testing.T) {
	// Simulate full bidirectional E2E:
	// Coordinator → Provider (request), Provider → Coordinator (response).
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	coordSession, _ := GenerateSessionKeys()

	// Coordinator encrypts request for provider.
	request := []byte(`{"messages":[{"role":"user","content":"what is 2+2?"}]}`)
	encRequest, _ := Encrypt(request, *providerPub, coordSession)

	// Provider decrypts.
	decRequest, err := DecryptWithPrivateKey(encRequest, *providerPriv)
	if err != nil {
		t.Fatalf("Provider decrypt request: %v", err)
	}
	if !bytes.Equal(request, decRequest) {
		t.Fatal("request content mismatch")
	}

	// Provider encrypts response for coordinator using coordinator's ephemeral public key.
	coordPub := coordSession.PublicKey
	providerRespSession := &SessionKeys{PrivateKey: *providerPriv, PublicKey: *providerPub}
	response := []byte(`{"choices":[{"message":{"content":"4"}}]}`)
	encResponse, _ := Encrypt(response, coordPub, providerRespSession)

	// Coordinator decrypts response.
	decResponse, err := Decrypt(encResponse, coordSession)
	if err != nil {
		t.Fatalf("Coordinator decrypt response: %v", err)
	}
	if !bytes.Equal(response, decResponse) {
		t.Fatal("response content mismatch")
	}
}

type encryptionFixtureCorpus struct {
	SchemaVersion uint32              `json:"schema_version"`
	Cases         []encryptionFixture `json:"cases"`
}

type encryptionFixture struct {
	Name                   string `json:"name"`
	RecipientPrivateKeyHex string `json:"recipient_private_key_hex"`
	SenderPublicKeyBase64  string `json:"sender_public_key_base64"`
	CiphertextBase64       string `json:"ciphertext_base64"`
	PlaintextUTF8          string `json:"plaintext_utf8"`
}

func TestDecryptSharedEncryptionVectors(t *testing.T) {
	encoded, err := os.ReadFile(filepath.Join(
		"..", "..", "..", "fixtures", "security", "v1", "encryption_vectors.json",
	))
	if err != nil {
		t.Fatal(err)
	}
	var corpus encryptionFixtureCorpus
	if err := decodeEncryptionFixture(encoded, &corpus); err != nil {
		t.Fatal(err)
	}
	if len(corpus.Cases) == 0 {
		t.Fatal("encryption fixture has no named cases")
	}

	seen := make(map[string]struct{}, len(corpus.Cases))
	for _, fixture := range corpus.Cases {
		t.Run(fixture.Name, func(t *testing.T) {
			if fixture.Name == "" {
				t.Fatal("encryption fixture case has no name")
			}
			if _, duplicate := seen[fixture.Name]; duplicate {
				t.Fatalf("duplicate encryption fixture case %q", fixture.Name)
			}
			seen[fixture.Name] = struct{}{}

			privateBytes, err := hex.DecodeString(fixture.RecipientPrivateKeyHex)
			if err != nil {
				t.Fatalf("decode recipient private key: %v", err)
			}
			if len(privateBytes) != 32 {
				t.Fatalf("recipient private key length = %d, want 32", len(privateBytes))
			}
			var privateKey [32]byte
			copy(privateKey[:], privateBytes)
			plaintext, err := DecryptWithPrivateKey(&EncryptedPayload{
				EphemeralPublicKey: fixture.SenderPublicKeyBase64,
				Ciphertext:         fixture.CiphertextBase64,
			}, privateKey)
			if err != nil {
				t.Fatalf("decrypt shared vector: %v", err)
			}
			if !bytes.Equal(plaintext, []byte(fixture.PlaintextUTF8)) {
				t.Fatalf("plaintext mismatch\nwant: %q\ngot:  %q", fixture.PlaintextUTF8, plaintext)
			}
		})
	}
}

func TestEncryptionFixtureRejectsSchemaDrift(t *testing.T) {
	for _, test := range []struct {
		name    string
		encoded string
	}{
		{name: "missing", encoded: `{"cases":[]}`},
		{name: "unknown", encoded: `{"schema_version":2,"cases":[]}`},
	} {
		t.Run(test.name, func(t *testing.T) {
			var corpus encryptionFixtureCorpus
			if err := decodeEncryptionFixture([]byte(test.encoded), &corpus); err == nil {
				t.Fatal("fixture schema drift was accepted")
			}
		})
	}
}

func decodeEncryptionFixture(encoded []byte, output any) error {
	var metadata struct {
		SchemaVersion *uint32 `json:"schema_version"`
	}
	if err := json.Unmarshal(encoded, &metadata); err != nil {
		return err
	}
	if metadata.SchemaVersion == nil {
		return errors.New("fixture schema version is missing")
	}
	if *metadata.SchemaVersion != 1 {
		return fmt.Errorf("unsupported fixture schema version %d", *metadata.SchemaVersion)
	}
	return json.Unmarshal(encoded, output)
}
