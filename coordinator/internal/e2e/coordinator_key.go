// coordinator_key.go derives a long-lived X25519 keypair the coordinator
// uses to receive sealed requests from senders (consumer/console-ui).
//
// Senders fetch the public key from GET /v1/encryption-key, NaCl-Box-seal
// their request body to it, and POST as application/eigeninference-sealed+json.
// Only the coordinator (which knows the private key) can decrypt.
//
// The private key is derived from the same BIP39 mnemonic used for billing,
// but with a distinct HKDF domain so the two keys are unrelated.

package e2e

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strings"

	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
	"golang.org/x/crypto/pbkdf2"

	"crypto/sha512"
)

// CoordinatorKeyHKDFInfo is the HKDF info string used to separate the
// X25519 encryption key from any other key derived from the same mnemonic.
// Bumping the version here rotates the coordinator key for all senders.
const CoordinatorKeyHKDFInfo = "eigeninference-coordinator-e2e-v1"

// CoordinatorKey is the long-lived X25519 keypair plus a short kid that
// senders use to detect rotations and refresh their cached pubkey.
type CoordinatorKey struct {
	KID        string   // first 16 hex chars of SHA-256(public_key)
	PublicKey  [32]byte // X25519 public key
	PrivateKey [32]byte // X25519 private key — never serialized
}

// DeriveCoordinatorKey derives the coordinator's X25519 keypair from a BIP39
// mnemonic. It returns ErrNoMnemonic if mnemonic is empty so callers can run
// the coordinator in environments without billing configured (the encryption
// endpoint will simply be unavailable).
func DeriveCoordinatorKey(mnemonic string) (*CoordinatorKey, error) {
	mnemonic = strings.TrimSpace(mnemonic)
	if mnemonic == "" {
		return nil, ErrNoMnemonic
	}

	words := strings.Fields(mnemonic)
	if len(words) != 12 && len(words) != 24 {
		return nil, fmt.Errorf("mnemonic must be 12 or 24 words, got %d", len(words))
	}

	// BIP39 seed (same plumbing as billing.DeriveKeypairFromMnemonic; we keep
	// this local instead of importing billing to avoid a dependency cycle and
	// keep the e2e package self-contained for testing).
	seed := pbkdf2.Key([]byte(mnemonic), []byte("mnemonic"), 2048, 64, sha512.New)

	// HKDF-SHA256 with a coordinator-specific info string to derive 32 bytes
	// of X25519 private-key material. Domain separation ensures this key
	// cannot collide with the Solana keypair derived from the same seed.
	r := hkdf.New(sha256.New, seed, nil, []byte(CoordinatorKeyHKDFInfo))
	var priv [32]byte
	if _, err := io.ReadFull(r, priv[:]); err != nil {
		return nil, fmt.Errorf("hkdf read: %w", err)
	}

	pub, err := curve25519.X25519(priv[:], curve25519.Basepoint)
	if err != nil {
		return nil, fmt.Errorf("derive x25519 public key: %w", err)
	}

	var pubArr [32]byte
	copy(pubArr[:], pub)

	sum := sha256.Sum256(pubArr[:])
	kid := hex.EncodeToString(sum[:8]) // 16 hex chars

	return &CoordinatorKey{
		KID:        kid,
		PublicKey:  pubArr,
		PrivateKey: priv,
	}, nil
}

// ErrNoMnemonic is returned when no mnemonic is configured so the coordinator
// can boot without sender encryption (dev/test environments).
var ErrNoMnemonic = errors.New("no mnemonic configured for coordinator key derivation")
