package api

import (
	"crypto/sha256"
	"encoding/hex"
)

func providerTokenHash(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}
