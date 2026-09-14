package releasepolicy

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

func NormalizeSHA256Hex(value, field string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if len(value) != sha256.Size*2 {
		return "", fmt.Errorf("%s must be a 64-character SHA-256 hex digest", field)
	}
	if _, err := hex.DecodeString(value); err != nil {
		return "", fmt.Errorf("%s must be a valid SHA-256 hex digest", field)
	}
	return value, nil
}
