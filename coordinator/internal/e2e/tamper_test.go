package e2e

// Tamper detection tests for E2E encryption.
// Verifies that corrupted nonces, truncated data, weak keys, and
// replayed payloads are all handled correctly.

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
)

func TestDecryptTamperedNonce(t *testing.T) {
	// Encrypt a message, then flip bits in the nonce portion.
	sender := generateSessionKeys(t)
	recipientPub, recipientPriv := generateBoxKeys(t)

	payload := encryptForTest(t, []byte("secret message"), *recipientPub, sender)

	// Decode ciphertext, tamper with nonce (first 24 bytes), re-encode
	raw := decodeBase64ForTest(t, payload.Ciphertext)
	raw[0] ^= 0xFF  // flip first byte of nonce
	raw[12] ^= 0xFF // flip middle byte of nonce
	payload.Ciphertext = base64.StdEncoding.EncodeToString(raw)

	_, err := DecryptWithPrivateKey(payload, *recipientPriv)
	if err == nil {
		t.Fatal("expected decryption to fail with tampered nonce")
	}
}

func TestDecryptTruncatedEncryptedData(t *testing.T) {
	sender := generateSessionKeys(t)
	recipientPub, recipientPriv := generateBoxKeys(t)

	payload := encryptForTest(t, []byte("a longer message to have more ciphertext"), *recipientPub, sender)

	// Keep the nonce (24 bytes) but truncate the encrypted portion
	raw := decodeBase64ForTest(t, payload.Ciphertext)

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
			p := &EncryptedPayload{
				EphemeralPublicKey: payload.EphemeralPublicKey,
				Ciphertext:         base64.StdEncoding.EncodeToString(tc.data),
			}
			_, err := DecryptWithPrivateKey(p, *recipientPriv)
			if err == nil {
				t.Errorf("expected decryption to fail with %s", tc.name)
			}
		})
	}
}

func TestDecryptRejectsMalformedPayload(t *testing.T) {
	_, recipientPriv := generateBoxKeys(t)
	validPublicKey := base64.StdEncoding.EncodeToString(make([]byte, 32))
	validCiphertext := base64.StdEncoding.EncodeToString(make([]byte, 48))
	tests := []struct {
		name          string
		payload       EncryptedPayload
		errorContains string
	}{
		{
			name: "ciphertext shorter than nonce",
			payload: EncryptedPayload{
				EphemeralPublicKey: validPublicKey,
				Ciphertext:         base64.StdEncoding.EncodeToString(make([]byte, 10)),
			},
		},
		{
			name: "invalid ciphertext base64",
			payload: EncryptedPayload{
				EphemeralPublicKey: validPublicKey,
				Ciphertext:         "not-valid-base64!!!",
			},
		},
		{
			name: "invalid public key base64",
			payload: EncryptedPayload{
				EphemeralPublicKey: "not-valid!!!",
				Ciphertext:         validCiphertext,
			},
		},
		{
			name: "wrong public key length",
			payload: EncryptedPayload{
				EphemeralPublicKey: base64.StdEncoding.EncodeToString(make([]byte, 16)),
				Ciphertext:         validCiphertext,
			},
			errorContains: "length",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, err := DecryptWithPrivateKey(&tc.payload, *recipientPriv)
			if err == nil {
				t.Fatal("expected malformed payload to be rejected")
			}
			if tc.errorContains != "" && !strings.Contains(err.Error(), tc.errorContains) {
				t.Fatalf("error %q does not contain %q", err, tc.errorContains)
			}
		})
	}
}

func TestDecryptTamperedEphemeralPublicKey(t *testing.T) {
	// Valid base64 but corrupted key bytes
	sender := generateSessionKeys(t)
	recipientPub, recipientPriv := generateBoxKeys(t)

	payload := encryptForTest(t, []byte("secret"), *recipientPub, sender)

	// Corrupt the ephemeral public key (valid base64, wrong key)
	keyBytes := decodeBase64ForTest(t, payload.EphemeralPublicKey)
	keyBytes[0] ^= 0xFF
	keyBytes[31] ^= 0xFF
	payload.EphemeralPublicKey = base64.StdEncoding.EncodeToString(keyBytes)

	_, err := DecryptWithPrivateKey(payload, *recipientPriv)
	if err == nil {
		t.Fatal("expected decryption to fail with corrupted ephemeral key")
	}
}

func TestDecryptAllZeroKey(t *testing.T) {
	sender := generateSessionKeys(t)
	recipientPub, recipientPriv := generateBoxKeys(t)

	payload := encryptForTest(t, []byte("test"), *recipientPub, sender)

	// Replace ephemeral key with all zeros
	var zeroKey [32]byte
	payload.EphemeralPublicKey = base64.StdEncoding.EncodeToString(zeroKey[:])

	_, err := DecryptWithPrivateKey(payload, *recipientPriv)
	if err == nil {
		t.Fatal("expected decryption to fail with all-zero ephemeral key")
	}
}

func TestReplayDecryptionSucceeds(t *testing.T) {
	// Same encrypted payload should decrypt successfully multiple times.
	// NaCl Box does NOT prevent replay — that's the coordinator's job.
	sender := generateSessionKeys(t)
	recipientPub, recipientPriv := generateBoxKeys(t)

	payload := encryptForTest(t, []byte("replay me"), *recipientPub, sender)

	for i := range 5 {
		plaintext, err := DecryptWithPrivateKey(payload, *recipientPriv)
		if err != nil {
			t.Fatalf("replay attempt %d failed: %v", i, err)
		}
		if string(plaintext) != "replay me" {
			t.Fatalf("replay attempt %d: wrong plaintext", i)
		}
	}
}

func TestCiphertextBoundaryLengths(t *testing.T) {
	sender := generateSessionKeys(t)
	recipientPub, recipientPriv := generateBoxKeys(t)

	// Test various plaintext sizes including boundaries
	sizes := []int{0, 1, 15, 16, 17, 23, 24, 25, 31, 32, 33, 255, 256, 1024, 65536}
	for _, size := range sizes {
		t.Run(fmt.Sprintf("%d_bytes", size), func(t *testing.T) {
			plaintext := make([]byte, size)
			if _, err := rand.Read(plaintext); err != nil {
				t.Fatalf("fill plaintext: %v", err)
			}

			payload, err := Encrypt(plaintext, *recipientPub, sender)
			if err != nil {
				t.Fatalf("encrypt %d bytes: %v", size, err)
			}

			decrypted, err := DecryptWithPrivateKey(payload, *recipientPriv)
			if err != nil {
				t.Fatalf("decrypt %d bytes: %v", size, err)
			}

			if len(decrypted) != size {
				t.Fatalf("expected %d bytes, got %d", size, len(decrypted))
			}
		})
	}
}
