package e2e

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"testing"

	"golang.org/x/crypto/nacl/box"
)

// TestPrecomputedSharedKeyRoundTrip verifies the memoized-key decrypt path:
// Encrypt with a recipient keypair, then decrypt via PrecomputeSharedKey +
// DecryptWithSharedKey. The result must equal the plaintext AND the output of
// the existing Decrypt path, so the two paths are interchangeable.
func TestPrecomputedSharedKeyRoundTrip(t *testing.T) {
	recipientPub, recipientPriv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate recipient keys: %v", err)
	}
	sender, err := GenerateSessionKeys()
	if err != nil {
		t.Fatalf("GenerateSessionKeys: %v", err)
	}

	plaintext := []byte(`data: {"choices":[{"delta":{"content":"tok"}}]}`)
	payload, err := Encrypt(plaintext, *recipientPub, sender)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// The sender public key travels in the payload; parse it the way a real
	// recipient would rather than trusting local state.
	senderPub, err := ParsePublicKey(payload.EphemeralPublicKey)
	if err != nil {
		t.Fatalf("ParsePublicKey: %v", err)
	}
	if senderPub != sender.PublicKey {
		t.Fatal("payload ephemeral key does not match sender public key")
	}

	shared := PrecomputeSharedKey(&senderPub, recipientPriv)
	got, err := DecryptWithSharedKey(payload, shared)
	if err != nil {
		t.Fatalf("DecryptWithSharedKey: %v", err)
	}
	if !bytes.Equal(got, plaintext) {
		t.Errorf("shared-key plaintext = %q, want %q", got, plaintext)
	}

	// Equivalence with the non-precomputed path.
	viaDecrypt, err := Decrypt(payload, &SessionKeys{PrivateKey: *recipientPriv})
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !bytes.Equal(got, viaDecrypt) {
		t.Errorf("shared-key path = %q, Decrypt path = %q — must be identical", got, viaDecrypt)
	}
}

// TestPrecomputedSharedKeyProviderToCoordinatorDirection pins the exact
// direction api/provider.go uses on the chunk hot path: the provider encrypts
// a response chunk with (provider private, coordinator session public) via
// Encrypt, and the coordinator decrypts with
// PrecomputeSharedKey(providerPub, sessionPriv) + DecryptWithSharedKey.
func TestPrecomputedSharedKeyProviderToCoordinatorDirection(t *testing.T) {
	providerPub, providerPriv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate provider keys: %v", err)
	}
	coordSession, err := GenerateSessionKeys()
	if err != nil {
		t.Fatalf("GenerateSessionKeys: %v", err)
	}

	chunk := []byte(`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"secret"}}]}`)
	providerSession := &SessionKeys{PublicKey: *providerPub, PrivateKey: *providerPriv}
	payload, err := Encrypt(chunk, coordSession.PublicKey, providerSession)
	if err != nil {
		t.Fatalf("provider Encrypt: %v", err)
	}

	// handleChunk verifies the chunk's ephemeral key matches the provider's
	// registered key before using the cached shared key — pin that invariant.
	if payload.EphemeralPublicKey != base64.StdEncoding.EncodeToString(providerPub[:]) {
		t.Fatal("chunk ephemeral key should be the provider public key")
	}

	// Coordinator side: shared key from (provider public, session private).
	shared := PrecomputeSharedKey(providerPub, &coordSession.PrivateKey)
	got, err := DecryptWithSharedKey(payload, shared)
	if err != nil {
		t.Fatalf("DecryptWithSharedKey: %v", err)
	}
	if !bytes.Equal(got, chunk) {
		t.Errorf("decrypted chunk = %q, want %q", got, chunk)
	}

	// Must match the classic Decrypt path used before memoization.
	viaDecrypt, err := Decrypt(payload, coordSession)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !bytes.Equal(got, viaDecrypt) {
		t.Errorf("shared-key path = %q, Decrypt path = %q — must be identical", got, viaDecrypt)
	}
}

func TestDecryptWithSharedKeyTamperedCiphertext(t *testing.T) {
	recipientPub, recipientPriv := generateBoxKeys(t)
	sender := generateSessionKeys(t)

	payload, err := Encrypt([]byte("authentic message"), *recipientPub, sender)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	shared := PrecomputeSharedKey(&sender.PublicKey, recipientPriv)

	ct := decodeBase64ForTest(t, payload.Ciphertext)
	ct[len(ct)-1] ^= 0xFF
	payload.Ciphertext = base64.StdEncoding.EncodeToString(ct)

	if _, err := DecryptWithSharedKey(payload, shared); err == nil {
		t.Error("tampered ciphertext should fail to decrypt")
	}
}

func TestDecryptWithSharedKeyTruncatedCiphertext(t *testing.T) {
	recipientPub, recipientPriv := generateBoxKeys(t)
	sender := generateSessionKeys(t)
	shared := PrecomputeSharedKey(&sender.PublicKey, recipientPriv)

	payload, err := Encrypt([]byte("authentic message"), *recipientPub, sender)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// Truncated below the 24-byte nonce prefix.
	payload.Ciphertext = base64.StdEncoding.EncodeToString(make([]byte, 10))
	if _, err := DecryptWithSharedKey(payload, shared); err == nil {
		t.Error("ciphertext shorter than the nonce should fail")
	}

	// Truncated mid-ciphertext (nonce intact, Poly1305 tag broken).
	full := encryptForTest(t, []byte("authentic message"), *recipientPub, sender)
	ct := decodeBase64ForTest(t, full.Ciphertext)
	full.Ciphertext = base64.StdEncoding.EncodeToString(ct[:len(ct)-1])
	if _, err := DecryptWithSharedKey(full, shared); err == nil {
		t.Error("truncated ciphertext should fail authentication")
	}
}

func TestDecryptWithSharedKeyInvalidBase64(t *testing.T) {
	_, recipientPriv := generateBoxKeys(t)
	sender := generateSessionKeys(t)
	shared := PrecomputeSharedKey(&sender.PublicKey, recipientPriv)

	payload := &EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(sender.PublicKey[:]),
		Ciphertext:         "not-valid-base64!!!",
	}
	if _, err := DecryptWithSharedKey(payload, shared); err == nil {
		t.Error("invalid base64 ciphertext should fail")
	}
}

func TestDecryptWithSharedKeyWrongKey(t *testing.T) {
	recipientPub, _ := generateBoxKeys(t)
	_, wrongPriv := generateBoxKeys(t)
	sender := generateSessionKeys(t)

	payload, err := Encrypt([]byte("secret"), *recipientPub, sender)
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	wrongShared := PrecomputeSharedKey(&sender.PublicKey, wrongPriv)
	if _, err := DecryptWithSharedKey(payload, wrongShared); err == nil {
		t.Error("decryption with a shared key from the wrong private key should fail")
	}
}
