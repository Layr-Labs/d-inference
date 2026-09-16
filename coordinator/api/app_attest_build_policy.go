package api

import (
	"encoding/hex"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/appattest"
)

func qualifiedAppAttestBuild(configured, hash string) bool {
	if !appAttestSHA256Hex(hash) {
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
func qualifiedAppAttestMeasurement(configured, binaryHash string, metadata *appattest.Key) (known, matched bool) {
	measurement := metadata.CodeDirectorySHA256()
	if !appAttestSHA256Hex(binaryHash) || len(measurement) == 0 || strings.TrimSpace(configured) == "" {
		return false, false
	}
	expected := ""
	for _, pair := range strings.Split(configured, ",") {
		binary, code, ok := strings.Cut(strings.TrimSpace(pair), ":")
		if !ok || !appAttestSHA256Hex(binary) || !appAttestSHA256Hex(code) {
			return false, false
		}
		if binary == binaryHash {
			if expected != "" && expected != code {
				return false, false // Conflicting qualification cannot authorize.
			}
			expected = code
		}
	}
	return expected != "", expected != "" && expected == hex.EncodeToString(measurement)
}

func appAttestSHA256Hex(hash string) bool {
	if len(hash) != 64 || strings.ToLower(hash) != hash {
		return false
	}
	_, err := hex.DecodeString(hash)
	return err == nil
}
