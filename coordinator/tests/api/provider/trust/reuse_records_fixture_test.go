package trust_test

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Two distinct, valid 64-char SHA-256 hex digests for binary-hash gate tests.
var (
	trHashA = strings.Repeat("a", 64)
	trHashB = strings.Repeat("b", 64)
	trHashC = strings.Repeat("c", 64)
	trHashD = strings.Repeat("d", 64)
)

// hardwareReuseRecord builds a fresh, all-gates-good record for the given device.
func hardwareReuseRecord(seKey, serial, binaryHash string, at time.Time) store.ProviderTrustReuse {
	return store.ProviderTrustReuse{
		SEPubKey:                seKey,
		Serial:                  serial,
		TrustLevel:              string(registry.TrustHardware),
		LastVerifiedBinaryHash:  binaryHash,
		SIPEnabled:              true,
		SecureBootFull:          true,
		MDAUDID:                 "UDID-1",
		HardwareProofVerifiedAt: at,
		EvidenceGeneration:      1,
	}
}
