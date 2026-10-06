// Package devicecode generates user-facing pairing codes and token digests.
package devicecode

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"math/big"
)

// Generate creates a short human-readable code without ambiguous characters.
func Generate() (string, error) {
	const charset = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	code := make([]byte, 8)
	for i := range code {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			return "", err
		}
		code[i] = charset[n.Int64()]
	}
	return string(code[:4]) + "-" + string(code[4:]), nil
}

// Hash returns the hex-encoded SHA-256 digest stored for a device token.
func Hash(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
