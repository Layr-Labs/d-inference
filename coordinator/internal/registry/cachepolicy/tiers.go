package cachepolicy

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Tiers share the nonce and independently verified prompt plan, but never
// share publication, sequence, epoch, or durability claims.
func Tier(tier string) bool {
	return tier == "ssd" || tier == "memory"
}

func ExplicitCheckpoints(tier string, capability protocol.PrefixCacheV2Capability) bool {
	return tier == "memory" ||
		(tier == "ssd" && capability.ReadyBoundaryMode == protocol.PrefixCacheReadyBoundaryCheckpoint)
}

func ReadyAnchorLimit(tier string, capability protocol.PrefixCacheV2Capability) int {
	if ExplicitCheckpoints(tier, capability) {
		return MaxCheckpointReadyAnchors
	}
	return 2
}
