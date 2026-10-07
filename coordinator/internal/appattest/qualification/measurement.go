// Package qualification evaluates release and Apple code measurement evidence.
package qualification

import (
	"encoding/hex"
	"strings"
)

func Build(configured, hash string) bool {
	if !SHA256Hex(hash) {
		return false
	}
	for _, candidate := range strings.Split(configured, ",") {
		if strings.TrimSpace(candidate) == hash {
			return true
		}
	}
	return false
}

// Explicit binary-SHA256:CodeDirectory-SHA256 pairs come from qualification of
// the same final signed artifact. No client field can add a mapping. The active
// release catalog and separate qualification allowlist must also approve it.
func Code(configured, binaryHash, measurement string) (known, matched bool) {
	if !SHA256Hex(binaryHash) || !SHA256Hex(measurement) || strings.TrimSpace(configured) == "" {
		return false, false
	}
	expected := ""
	for _, pair := range strings.Split(configured, ",") {
		binary, code, ok := strings.Cut(strings.TrimSpace(pair), ":")
		if !ok || !SHA256Hex(binary) || !SHA256Hex(code) {
			return false, false
		}
		if binary == binaryHash {
			if expected != "" && expected != code {
				return false, false // Conflicting qualification cannot authorize.
			}
			expected = code
		}
	}
	return expected != "", expected != "" && expected == measurement
}

func SHA256Hex(hash string) bool {
	if len(hash) != 64 || strings.ToLower(hash) != hash {
		return false
	}
	_, err := hex.DecodeString(hash)
	return err == nil
}

func SHA256PrefixHex(hash string) bool {
	if len(hash) != 40 || strings.ToLower(hash) != hash {
		return false
	}
	_, err := hex.DecodeString(hash)
	return err == nil
}
