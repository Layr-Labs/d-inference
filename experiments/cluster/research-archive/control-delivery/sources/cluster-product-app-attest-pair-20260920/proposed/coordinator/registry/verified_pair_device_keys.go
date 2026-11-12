package registry

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Caller holds p.mu. These are conservative exclusion observations, never an
// admission authority. Keep signer/machine continuity even after lease expiry;
// a reconnect cannot turn expired proof into reusable device capacity.
func verifiedPairObservedDeviceKeysLocked(p *Provider) []string {
	keys := make([]string, 0, 3)
	if a := p.AttestationResult; a != nil {
		if signer, err := protocol.NativeControlSigningKeyIdentity(a.PublicKey); err == nil {
			keys = append(keys, "signer:"+hex.EncodeToString(signer[:]))
		}
		// App Attest registration may carry an unverified claimed serial. It must
		// never acquire the identity/authority of a genuine MDA serial.
		if a.Valid && p.MDAVerified && a.SerialNumber != "" {
			keys = append(keys, "serial:"+a.SerialNumber)
		}
	}
	if p.verifiedMachineAccount != "" && p.verifiedMachineAccount == p.AccountID && p.verifiedMachineID != "" {
		b := []byte("darkbloom/pair-machine-hold/v1\x00")
		for _, value := range []string{p.verifiedMachineAccount, p.verifiedMachineID} {
			b = binary.BigEndian.AppendUint32(b, uint32(len(value)))
			b = append(b, value...)
		}
		digest := sha256.Sum256(b)
		keys = append(keys, "machine:"+hex.EncodeToString(digest[:]))
	}
	return keys
}

func verifiedPairKeysOverlap(a, b []string) bool {
	for _, x := range a {
		for _, y := range b {
			if x == y {
				return true
			}
		}
	}
	return false
}
