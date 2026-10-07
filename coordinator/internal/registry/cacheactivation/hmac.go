package cacheactivation

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
)

// HMACBytes authenticates length-prefixed fields so concatenations cannot alias.
func HMACBytes(key []byte, parts ...[]byte) []byte {
	m := hmac.New(sha256.New, key)
	var n [4]byte
	for _, part := range parts {
		binary.BigEndian.PutUint32(n[:], uint32(len(part)))
		_, _ = m.Write(n[:])
		_, _ = m.Write(part)
	}
	return m.Sum(nil)
}

func OpaqueHMAC(key []byte, parts ...string) string {
	values := make([][]byte, 0, len(parts))
	for _, part := range parts {
		values = append(values, []byte(part))
	}
	return base64.RawURLEncoding.EncodeToString(HMACBytes(key, values...))
}
