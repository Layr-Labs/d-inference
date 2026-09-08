package attestation

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"fmt"
)

// ProcessPostureNonce creates request context containing the claimed SE and
// process public keys and the server's revocation generation. DeviceInformation
// MDA can echo these bytes in an Apple-signed certificate; it does NOT attest
// ownership, residency or exclusivity of either claimed private key. Sound
// device/process bootstrap and key-possession verification are separate
// requirements. This helper alone is not a process or hardware attestation.
func ProcessPostureNonce(seKey, processKey string, revocationGenerations ...uint64) ([]byte, error) {
	se, err := base64.StdEncoding.DecodeString(seKey)
	if err != nil {
		return nil, fmt.Errorf("invalid SE identity")
	}
	if _, err := ParseP256PublicKey(se); err != nil {
		return nil, err
	}
	process, err := base64.StdEncoding.DecodeString(processKey)
	if err != nil || len(process) != 32 {
		return nil, fmt.Errorf("invalid process identity")
	}
	h := sha256.New()
	h.Write([]byte("darkbloom/process-posture/v1\x00"))
	h.Write(se)
	h.Write(process)
	var generation [8]byte
	if len(revocationGenerations) > 0 {
		binary.BigEndian.PutUint64(generation[:], revocationGenerations[0])
	}
	h.Write(generation[:])
	return h.Sum(nil), nil
}
