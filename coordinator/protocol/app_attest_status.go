package protocol

import (
	"crypto/sha256"
	"encoding/binary"
)

// These are app-derived claims, authenticated by an assertion, not measurements
// independently certified by Apple. Keep the field order mirrored in Swift.
type AppAttestStatus struct {
	OSVersion  string `json:"os_version"`
	OSBuild    string `json:"os_build"`
	AppVersion string `json:"app_version"`
	Chip       string `json:"chip"`
	BinaryHash string `json:"binary_hash"`
}

func (s *AppAttestStatus) Values() []string {
	if s == nil {
		return []string{"", "", "", "", ""}
	}
	return []string{s.OSVersion, s.OSBuild, s.AppVersion, s.Chip, s.BinaryHash}
}

func AppAttestShadowHashV2(action, session, environment, keyID, challenge, publicKey, accountScope string, status *AppAttestStatus) [32]byte {
	h := sha256.New()
	values := append([]string{"darkbloom.app-attest.shadow.v2", action, session, environment, keyID, challenge, publicKey, accountScope}, status.Values()...)
	for _, value := range values {
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], uint32(len(value)))
		h.Write(length[:])
		h.Write([]byte(value))
	}
	var result [32]byte
	copy(result[:], h.Sum(nil))
	return result
}
