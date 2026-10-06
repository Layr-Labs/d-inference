package store

import (
	"crypto/sha256"
	"encoding/hex"
)

// hashKey returns the SHA-256 hex digest of the given API key.
func hashKey(key string) string {
	h := sha256.Sum256([]byte(key))
	return hex.EncodeToString(h[:])
}

// HashKey returns the SHA-256 hex digest of the given API key.
func HashKey(key string) string { return hashKey(key) }
