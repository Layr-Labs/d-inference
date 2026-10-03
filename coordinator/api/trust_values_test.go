package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"time"
)

// Cache contract shared by composed HTTP endpoint tests.
const providerAttestationCacheKey = "providers:attestation:v1"

var (
	trHashA = strings.Repeat("a", 64)
	trHashB = strings.Repeat("b", 64)
	trHashC = strings.Repeat("c", 64)
	trHashD = strings.Repeat("d", 64)
)

func trBoolPtr(v bool) *bool { return &v }
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

// TestTrustReuseCacheReuseAndWindow covers the core reuse decision with a fake
// clock: a fresh hardware record with matching identity + binary reuses, and reuse
// expires after the window. Mirrors TestCodeAttestThrottleBudgetAndReuse.
