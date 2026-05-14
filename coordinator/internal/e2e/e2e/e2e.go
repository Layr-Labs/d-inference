// Package e2e provides end-to-end encryption between the coordinator and
// provider's hardened process.
//
// Prompts are encrypted with the provider's X25519 public key (from their
// Secure Enclave attestation) before being sent over WebSocket. Only the
// provider's hardened binary can decrypt them — not even if the provider
// runs a MITM proxy on their own network.
//
// Uses NaCl Box (X25519 + XSalsa20-Poly1305) — the same primitives as
// the provider's Rust crypto module, ensuring cross-language compatibility.
//
// Flow:
//  1. Coordinator generates ephemeral X25519 key pair per request (forward secrecy)
//  2. Encrypts prompt with: ephemeral private + provider public → shared secret
//  3. Sends: ephemeral public key + nonce + ciphertext
//  4. Provider decrypts with: provider private + ephemeral public → same shared secret
//  5. Provider encrypts response with: provider private + ephemeral public
//  6. Coordinator decrypts with: ephemeral private + provider public
package e2e

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"

	"golang.org/x/crypto/nacl/box"
)

// EncryptedPayload contains an encrypted message and the ephemeral public key
// needed to decrypt it.
type EncryptedPayload struct {
	// EphemeralPublicKey is the sender's ephemeral X25519 public key (base64).
	// The recipient combines this with their private key to derive the shared secret.
	EphemeralPublicKey string `json:"ephemeral_public_key"`
	// Ciphertext is the encrypted data (base64): 24-byte nonce || encrypted+authenticated data.
	Ciphertext string `json:"ciphertext"`
}

// SessionKeys holds the ephemeral key pair for a single request.
// The coordinator creates one per inference request for forward secrecy.
type SessionKeys struct {
	PublicKey  [32]byte
	PrivateKey [32]byte
}

// GenerateSessionKeys creates a new ephemeral X25519 key pair.
func GenerateSessionKeys() (*SessionKeys, error) {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("failed to generate session keys: %w", err)
	}
	return &SessionKeys{
		PublicKey:  *pub,
		PrivateKey: *priv,
	}, nil
}

// Encrypt encrypts a plaintext message for a recipient given their public key.
// Returns an EncryptedPayload containing the ephemeral public key and ciphertext.
//
// The ciphertext format is: 24-byte nonce || NaCl Box encrypted data.
// This is compatible with the Rust provider's crypto_box crate.
func Encrypt(plaintext []byte, recipientPublicKey [32]byte, session *SessionKeys) (*EncryptedPayload, error) {
	// Generate random nonce
	var nonce [24]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return nil, fmt.Errorf("failed to generate nonce: %w", err)
	}

	// Encrypt with NaCl Box: shared secret from (our private + their public)
	encrypted := box.Seal(nonce[:], plaintext, &nonce, &recipientPublicKey, &session.PrivateKey)

	return &EncryptedPayload{
		EphemeralPublicKey: base64.StdEncoding.EncodeToString(session.PublicKey[:]),
		Ciphertext:         base64.StdEncoding.EncodeToString(encrypted),
	}, nil
}

// Decrypt decrypts an EncryptedPayload using the session's private key and
// the sender's public key (from the payload).
func Decrypt(payload *EncryptedPayload, session *SessionKeys) ([]byte, error) {
	// Decode sender's public key
	senderPubBytes, err := base64.StdEncoding.DecodeString(payload.EphemeralPublicKey)
	if err != nil {
		return nil, fmt.Errorf("invalid ephemeral public key: %w", err)
	}
	if len(senderPubBytes) != 32 {
		return nil, fmt.Errorf("invalid public key length: %d", len(senderPubBytes))
	}
	var senderPub [32]byte
	copy(senderPub[:], senderPubBytes)

	// Decode ciphertext (nonce || encrypted data)
	ciphertext, err := base64.StdEncoding.DecodeString(payload.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("invalid ciphertext: %w", err)
	}
	if len(ciphertext) < 24 {
		return nil, errors.New("ciphertext too short")
	}

	// Extract nonce
	var nonce [24]byte
	copy(nonce[:], ciphertext[:24])

	// Decrypt
	plaintext, ok := box.Open(nil, ciphertext[24:], &nonce, &senderPub, &session.PrivateKey)
	if !ok {
		return nil, errors.New("decryption failed — wrong key or tampered data")
	}

	return plaintext, nil
}

// DecryptWithPrivateKey decrypts using a raw private key and the sender's public key.
func DecryptWithPrivateKey(payload *EncryptedPayload, privateKey [32]byte) ([]byte, error) {
	session := &SessionKeys{PrivateKey: privateKey}
	return Decrypt(payload, session)
}

// ParsePublicKey decodes a base64-encoded X25519 public key.
func ParsePublicKey(b64 string) ([32]byte, error) {
	var key [32]byte
	decoded, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return key, fmt.Errorf("invalid base64 public key: %w", err)
	}
	if len(decoded) != 32 {
		return key, fmt.Errorf("invalid public key length: %d (expected 32)", len(decoded))
	}
	copy(key[:], decoded)
	return key, nil
}
