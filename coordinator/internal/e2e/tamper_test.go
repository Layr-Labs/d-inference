package e2e_test

// Tamper detection tests for E2E encryption.
// Verifies that corrupted nonces, truncated data, weak keys, and
// replayed payloads are all handled correctly.

import (
	"crypto/rand"
	"encoding/base64"
	"testing"

	"github.com/eigeninference/coordinator/internal/e2e"
	"golang.org/x/crypto/nacl/box"
)

func TestDecryptTamperedNonce(t *testing.T) {
	// Encrypt a message, then flip bits in the nonce portion.
	sender, _ := e2e.GenerateSessionKeys()
	recipientPub, recipientPriv, _ := box.GenerateKey(rand.Reader)

	payload, err := e2e.Encrypt([]byte("secret message"), *recipientPub, sender)
	if err != nil {
		t.Fatal(err)
	}

	// Decode ciphertext, tamper with nonce (first 24 bytes), re-encode
	raw, _ := base64.StdEncoding.DecodeString(payload.Ciphertext)
	raw[0] ^= 0xFF  // flip first byte of nonce
	raw[12] ^= 0xFF // flip middle byte of nonce
	payload.Ciphertext = base64.StdEncoding.EncodeToString(raw)

	_, err = e2e.DecryptWithPrivateKey(payload, *recipientPriv)
	if err == nil {
		t.Fatal("expected decryption to fail with tampered nonce")
	}
}

func TestDecryptTruncatedEncryptedData(t *testing.T) {
	sender, _ := e2e.GenerateSessionKeys()
	recipientPub, recipientPriv, _ := box.GenerateKey(rand.Reader)

	payload, _ := e2e.Encrypt([]byte("a longer message to have more ciphertext"), *recipientPub, sender)

	// Keep the nonce (24 bytes) but truncate the encrypted portion
	raw, _ := base64.StdEncoding.DecodeString(payload.Ciphertext)

	cases := []struct {
		name string
		data []byte
	}{
		{"nonce_only", raw[:24]},
		{"nonce_plus_1", raw[:25]},
		{"half_ciphertext", raw[:len(raw)/2]},
		{"missing_last_byte", raw[:len(raw)-1]},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := &e2e.EncryptedPayload{
				EphemeralPublicKey: payload.EphemeralPublicKey,
				Ciphertext:         base64.StdEncoding.EncodeToString(tc.data),
			}
			_, err := e2e.DecryptWithPrivateKey(p, *recipientPriv)
			if err == nil {
				t.Errorf("expected decryption to fail with %s", tc.name)
			}
		})
	}
}

func TestDecryptTamperedEphemeralPublicKey(t *testing.T) {
	// Valid base64 but corrupted key bytes
	sender, _ := e2e.GenerateSessionKeys()
	recipientPub, recipientPriv, _ := box.GenerateKey(rand.Reader)

	payload, _ := e2e.Encrypt([]byte("secret"), *recipientPub, sender)

	// Corrupt the ephemeral public key (valid base64, wrong key)
	keyBytes, _ := base64.StdEncoding.DecodeString(payload.EphemeralPublicKey)
	keyBytes[0] ^= 0xFF
	keyBytes[31] ^= 0xFF
	payload.EphemeralPublicKey = base64.StdEncoding.EncodeToString(keyBytes)

	_, err := e2e.DecryptWithPrivateKey(payload, *recipientPriv)
	if err == nil {
		t.Fatal("expected decryption to fail with corrupted ephemeral key")
	}
}

func TestDecryptAllZeroKey(t *testing.T) {
	sender, _ := e2e.GenerateSessionKeys()
	recipientPub, recipientPriv, _ := box.GenerateKey(rand.Reader)

	payload, _ := e2e.Encrypt([]byte("test"), *recipientPub, sender)

	// Replace ephemeral key with all zeros
	var zeroKey [32]byte
	payload.EphemeralPublicKey = base64.StdEncoding.EncodeToString(zeroKey[:])

	_, err := e2e.DecryptWithPrivateKey(payload, *recipientPriv)
	if err == nil {
		t.Fatal("expected decryption to fail with all-zero ephemeral key")
	}
}

func TestReplayDecryptionSucceeds(t *testing.T) {
	// Same encrypted payload should decrypt successfully multiple times.
	// NaCl Box does NOT prevent replay — that's the coordinator's job.
	sender, _ := e2e.GenerateSessionKeys()
	recipientPub, recipientPriv, _ := box.GenerateKey(rand.Reader)

	payload, _ := e2e.Encrypt([]byte("replay me"), *recipientPub, sender)

	for i := 0; i < 5; i++ {
		plaintext, err := e2e.DecryptWithPrivateKey(payload, *recipientPriv)
		if err != nil {
			t.Fatalf("replay attempt %d failed: %v", i, err)
		}
		if string(plaintext) != "replay me" {
			t.Fatalf("replay attempt %d: wrong plaintext", i)
		}
	}
}

func TestCiphertextBoundaryLengths(t *testing.T) {
	sender, _ := e2e.GenerateSessionKeys()
	recipientPub, recipientPriv, _ := box.GenerateKey(rand.Reader)

	// Test various plaintext sizes including boundaries
	sizes := []int{0, 1, 15, 16, 17, 23, 24, 25, 31, 32, 33, 255, 256, 1024, 65536}
	for _, size := range sizes {
		t.Run("", func(t *testing.T) {
			plaintext := make([]byte, size)
			rand.Read(plaintext)

			payload, err := e2e.Encrypt(plaintext, *recipientPub, sender)
			if err != nil {
				t.Fatalf("encrypt %d bytes: %v", size, err)
			}

			decrypted, err := e2e.DecryptWithPrivateKey(payload, *recipientPriv)
			if err != nil {
				t.Fatalf("decrypt %d bytes: %v", size, err)
			}

			if len(decrypted) != size {
				t.Fatalf("expected %d bytes, got %d", size, len(decrypted))
			}
		})
	}
}
