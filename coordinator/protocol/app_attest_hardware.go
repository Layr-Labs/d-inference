package protocol

import (
	"crypto/sha256"
	"encoding/binary"
)

// Version 3 binds static hardware claims as measured by the signed app. These
// remain app measurements, not Apple-certified RAM or a physical identifier.
func (s *AppAttestStatus) HardwareValues() []string {
	if s == nil {
		return make([]string, 6)
	}
	return []string{s.MachineModel, s.MemoryGB, s.CPUTotal, s.CPUPerformance, s.CPUEfficiency, s.GPUCores}
}

func AppAttestShadowHashV3(action, session, environment, keyID, challenge, publicKey, accountScope string, status *AppAttestStatus) [32]byte {
	h := sha256.New()
	values := append([]string{"darkbloom.app-attest.shadow.v3", action, session, environment, keyID, challenge, publicKey, accountScope}, status.Values()...)
	values = append(values, status.HardwareValues()...)
	verificationKey := ""
	if status != nil {
		verificationKey = status.AttestationPublicKey
	}
	values = append(values, verificationKey)
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
