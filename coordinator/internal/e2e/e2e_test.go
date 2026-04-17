package e2e_test

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"strings"
	"testing"

	"github.com/eigeninference/coordinator/internal/e2e"
	"golang.org/x/crypto/nacl/box"
)

func TestGenerateSessionKeys(t *testing.T) {
	k1, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatalf("GenerateSessionKeys: %v", err)
	}
	k2, err := e2e.GenerateSessionKeys()
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
	session, _ := e2e.GenerateSessionKeys()

	plaintext := []byte(`{"model":"test","messages":[{"role":"user","content":"hello"}]}`)

	encrypted, err := e2e.Encrypt(plaintext, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// For decryption, the session's private key is the provider's private key.
	decrypted, err := e2e.Decrypt(encrypted, &e2e.SessionKeys{PrivateKey: *providerPriv})
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !bytes.Equal(plaintext, decrypted) {
		t.Errorf("plaintext mismatch: got %q, want %q", decrypted, plaintext)
	}
}

func TestEncryptDecryptWithPrivateKey(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := e2e.GenerateSessionKeys()

	plaintext := []byte("test payload for DecryptWithPrivateKey")
	encrypted, err := e2e.Encrypt(plaintext, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	decrypted, err := e2e.DecryptWithPrivateKey(encrypted, *providerPriv)
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
	session, _ := e2e.GenerateSessionKeys()

	encrypted, _ := e2e.Encrypt([]byte("secret"), *providerPub, session)

	_, err := e2e.DecryptWithPrivateKey(encrypted, *wrongPriv)
	if err == nil {
		t.Error("decryption with wrong key should fail")
	}
}

func TestEncryptionNonDeterministic(t *testing.T) {
	providerPub, _, _ := box.GenerateKey(rand.Reader)
	session, _ := e2e.GenerateSessionKeys()
	plaintext := []byte("same input")

	enc1, _ := e2e.Encrypt(plaintext, *providerPub, session)
	enc2, _ := e2e.Encrypt(plaintext, *providerPub, session)

	// Different nonces should produce different ciphertexts.
	if enc1.Ciphertext == enc2.Ciphertext {
		t.Error("two encryptions of same plaintext should produce different ciphertext (random nonce)")
	}
}

func TestDecryptTamperedCiphertext(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := e2e.GenerateSessionKeys()

	encrypted, _ := e2e.Encrypt([]byte("authentic message"), *providerPub, session)

	// Tamper with ciphertext.
	ct, _ := base64.StdEncoding.DecodeString(encrypted.Ciphertext)
	ct[len(ct)-1] ^= 0xFF // flip last byte
	encrypted.Ciphertext = base64.StdEncoding.EncodeToString(ct)

	_, err := e2e.DecryptWithPrivateKey(encrypted, *providerPriv)
	if err == nil {
		t.Error("decryption of tampered ciphertext should fail")
	}
}

func TestDecryptShortCiphertext(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &e2e.EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		Ciphertext:         base64.StdEncoding.EncodeToString(make([]byte, 10)), // too short for nonce
	}
	_, err := e2e.DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("ciphertext shorter than 24-byte nonce should fail")
	}
}

func TestDecryptInvalidBase64Ciphertext(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &e2e.EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		Ciphertext:         "not-valid-base64!!!",
	}
	_, err := e2e.DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("invalid base64 ciphertext should fail")
	}
}

func TestDecryptInvalidBase64PublicKey(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &e2e.EncryptedPayload{
		EphemeralPublicKey: "not-valid!!!",
		Ciphertext:         base64.StdEncoding.EncodeToString(make([]byte, 48)),
	}
	_, err := e2e.DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("invalid base64 public key should fail")
	}
}

func TestDecryptWrongLengthPublicKey(t *testing.T) {
	_, priv, _ := box.GenerateKey(rand.Reader)
	payload := &e2e.EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(make([]byte, 16)), // 16 != 32
		Ciphertext:         base64.StdEncoding.EncodeToString(make([]byte, 48)),
	}
	_, err := e2e.DecryptWithPrivateKey(payload, *priv)
	if err == nil {
		t.Error("public key of wrong length should fail")
	}
	if !strings.Contains(err.Error(), "length") {
		t.Errorf("error should mention length, got: %v", err)
	}
}

func TestEncryptEmptyPlaintext(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := e2e.GenerateSessionKeys()

	encrypted, err := e2e.Encrypt([]byte{}, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt empty: %v", err)
	}

	decrypted, err := e2e.DecryptWithPrivateKey(encrypted, *providerPriv)
	if err != nil {
		t.Fatalf("Decrypt empty: %v", err)
	}
	if len(decrypted) != 0 {
		t.Errorf("expected empty plaintext, got %d bytes", len(decrypted))
	}
}

func TestEncryptLargePayload(t *testing.T) {
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	session, _ := e2e.GenerateSessionKeys()

	// 1 MB payload (large prompt).
	plaintext := make([]byte, 1024*1024)
	rand.Read(plaintext)

	encrypted, err := e2e.Encrypt(plaintext, *providerPub, session)
	if err != nil {
		t.Fatalf("Encrypt large: %v", err)
	}

	decrypted, err := e2e.DecryptWithPrivateKey(encrypted, *providerPriv)
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

	parsed, err := e2e.ParsePublicKey(b64)
	if err != nil {
		t.Fatalf("ParsePublicKey: %v", err)
	}
	if parsed != *pub {
		t.Error("parsed key doesn't match original")
	}
}

func TestParsePublicKeyInvalid(t *testing.T) {
	if _, err := e2e.ParsePublicKey("not-base64!!!"); err == nil {
		t.Error("invalid base64 should fail")
	}
	if _, err := e2e.ParsePublicKey(base64.StdEncoding.EncodeToString(make([]byte, 16))); err == nil {
		t.Error("wrong length should fail")
	}
	if _, err := e2e.ParsePublicKey(""); err == nil {
		t.Error("empty string should fail")
	}
}

func TestBidirectionalEncryption(t *testing.T) {
	// Simulate full bidirectional E2E:
	// Coordinator → Provider (request), Provider → Coordinator (response).
	providerPub, providerPriv, _ := box.GenerateKey(rand.Reader)
	coordSession, _ := e2e.GenerateSessionKeys()

	// Coordinator encrypts request for provider.
	request := []byte(`{"messages":[{"role":"user","content":"what is 2+2?"}]}`)
	encRequest, _ := e2e.Encrypt(request, *providerPub, coordSession)

	// Provider decrypts.
	decRequest, err := e2e.DecryptWithPrivateKey(encRequest, *providerPriv)
	if err != nil {
		t.Fatalf("Provider decrypt request: %v", err)
	}
	if !bytes.Equal(request, decRequest) {
		t.Fatal("request content mismatch")
	}

	// Provider encrypts response for coordinator using coordinator's ephemeral public key.
	coordPub := coordSession.PublicKey
	providerRespSession := &e2e.SessionKeys{PrivateKey: *providerPriv, PublicKey: *providerPub}
	response := []byte(`{"choices":[{"message":{"content":"4"}}]}`)
	encResponse, _ := e2e.Encrypt(response, coordPub, providerRespSession)

	// Coordinator decrypts response.
	decResponse, err := e2e.Decrypt(encResponse, coordSession)
	if err != nil {
		t.Fatalf("Coordinator decrypt response: %v", err)
	}
	if !bytes.Equal(response, decResponse) {
		t.Fatal("response content mismatch")
	}
}
