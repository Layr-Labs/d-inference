package receipts

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Environment variable names (EIGENINFERENCE_ prefix, per coordinator/env).
const (
	envEnabled      = env.EnvPrefix + "_INFERENCE_RECEIPTS_ENABLED"
	envSigningKeyID = env.EnvPrefix + "_INFERENCE_RECEIPT_SIGNING_KEY_ID"
	envSigningKey   = env.EnvPrefix + "_INFERENCE_RECEIPT_SIGNING_KEY"
	envPublicKeys   = env.EnvPrefix + "_INFERENCE_RECEIPT_PUBLIC_KEYS"
)

// Config is the coordinator's receipt-signing configuration. Receipts are off
// unless Enabled. When enabled, every key field must validate: a receipt is
// only worth issuing if a verifier can check it against a published key, so a
// half-configured signer fails the boot (Check) instead of quietly serving
// requests that ask for a receipt with 503s.
type Config struct {
	Enabled bool
	// SigningKeyID names the active key in every envelope and in the public
	// key set. At most 128 UTF-8 bytes.
	SigningKeyID string
	// SigningKey is the secret: a standard-base64 32-byte Ed25519 seed or
	// 64-byte private key. Never logged or echoed in errors.
	SigningKey string
	// PublicKeysJSON maps retained key IDs to standard-base64 Ed25519 public
	// keys. Keys stay published after rotation because receipts they signed
	// remain retrievable for their whole lookup window.
	PublicKeysJSON string
	// malformedEnv names an ENABLED value that was set but unparseable. The
	// shared env helpers fall back silently, which would turn `ENABLED=ture`
	// into "off" without a trace; ReadConfig records it and Check reports it.
	malformedEnv []string
}

// ReadConfig builds a Config from EIGENINFERENCE_INFERENCE_RECEIPT* variables.
// The result is the raw operator intent; Check validates it.
func ReadConfig() Config {
	c := Config{
		SigningKeyID:   strings.TrimSpace(os.Getenv(envSigningKeyID)),
		SigningKey:     strings.TrimSpace(os.Getenv(envSigningKey)),
		PublicKeysJSON: strings.TrimSpace(os.Getenv(envPublicKeys)),
	}
	if v := strings.TrimSpace(os.Getenv(envEnabled)); v != "" {
		enabled, err := strconv.ParseBool(v)
		if err != nil {
			c.malformedEnv = append(c.malformedEnv, envEnabled)
		}
		c.Enabled = enabled
	}
	return c
}

// Check reports configuration that cannot produce verifiable receipts. A
// disabled config is always valid; key variables are ignored until enabled.
func (c Config) Check() error {
	if len(c.malformedEnv) > 0 {
		return fmt.Errorf("receipts: unparseable value(s) for %s", strings.Join(c.malformedEnv, ", "))
	}
	_, err := c.KeyRing()
	return err
}

// KeyRing is the coordinator's receipt signing identity: the active signer and
// every public key a verifier may still need, including the active one.
type KeyRing struct {
	signer     *Signer
	publicKeys map[string]ed25519.PublicKey
}

// KeyRing builds the signer and published key set. It returns (nil, nil) when
// receipts are disabled. Errors name the variable at fault, never its value.
func (c Config) KeyRing() (*KeyRing, error) {
	if !c.Enabled {
		return nil, nil
	}
	publicKeys := make(map[string]ed25519.PublicKey)
	if c.PublicKeysJSON != "" {
		var encoded map[string]string
		if err := json.Unmarshal([]byte(c.PublicKeysJSON), &encoded); err != nil {
			return nil, fmt.Errorf("receipts: %s must be a JSON object of key ID to base64 public key", envPublicKeys)
		}
		for keyID, value := range encoded {
			key, err := base64.StdEncoding.DecodeString(value)
			if err != nil || len(key) != ed25519.PublicKeySize || validateKeyID(keyID) != nil {
				return nil, fmt.Errorf("receipts: %s has an invalid entry for key ID %q", envPublicKeys, keyID)
			}
			publicKeys[keyID] = ed25519.PublicKey(key)
		}
	}
	if c.SigningKeyID == "" || c.SigningKey == "" {
		return nil, fmt.Errorf("receipts: %s and %s are required when %s is true", envSigningKeyID, envSigningKey, envEnabled)
	}
	privateKey, err := base64.StdEncoding.DecodeString(c.SigningKey)
	if err != nil {
		return nil, fmt.Errorf("receipts: %s must be standard base64", envSigningKey)
	}
	signer, err := NewSignerFromBytes(c.SigningKeyID, privateKey)
	if err != nil {
		return nil, fmt.Errorf("receipts: %s/%s: %w", envSigningKeyID, envSigningKey, err)
	}
	// A retained entry for the active ID must be the active key; otherwise the
	// published set would advertise a key that cannot verify new receipts.
	active := signer.PublicKey()
	if published, ok := publicKeys[c.SigningKeyID]; ok && !published.Equal(active) {
		return nil, errors.New("receipts: " + envPublicKeys + " lists the active key ID with a different public key")
	}
	publicKeys[c.SigningKeyID] = active
	return &KeyRing{signer: signer, publicKeys: publicKeys}, nil
}

// Signer returns the active signer.
func (k *KeyRing) Signer() *Signer {
	return k.signer
}

// PublicKey returns the verification key published for keyID.
func (k *KeyRing) PublicKey(keyID string) (ed25519.PublicKey, bool) {
	key, ok := k.publicKeys[keyID]
	return key, ok
}

// KeyIDs returns every published key ID in sorted order.
func (k *KeyRing) KeyIDs() []string {
	ids := make([]string, 0, len(k.publicKeys))
	for keyID := range k.publicKeys {
		ids = append(ids, keyID)
	}
	sort.Strings(ids)
	return ids
}
