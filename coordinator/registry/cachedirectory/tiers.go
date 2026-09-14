package cachedirectory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Tiers share the nonce and independently verified prompt plan, but never
// share publication, sequence, epoch, or durability claims.
func ValidTier(tier string) bool {
	return tier == "ssd" || tier == "memory"
}

func (attempt *Attempt[C]) capability(tier string) protocol.PrefixCacheV2Capability {
	if tier == "memory" {
		return attempt.MemoryCapability
	}
	return attempt.V2Capability
}

func (attempt *Attempt[C]) lookupSeen(tier string) bool {
	if tier == "memory" {
		return attempt.MemoryLookupSeen
	}
	return attempt.LookupSeen
}

func (attempt *Attempt[C]) lastReadyAnchor(tier string) protocol.PrefixCacheAnchor {
	if tier == "memory" {
		return attempt.MemoryLastReadyAnchor
	}
	return attempt.LastReadyAnchor
}

func usesExplicitCacheCheckpoints(tier string, capability protocol.PrefixCacheV2Capability) bool {
	return tier == "memory" ||
		(tier == "ssd" && capability.ReadyBoundaryMode == protocol.PrefixCacheReadyBoundaryCheckpoint)
}

func cacheReadyAnchorLimit(tier string, capability protocol.PrefixCacheV2Capability) int {
	if usesExplicitCacheCheckpoints(tier, capability) {
		return MaxCheckpointReadyAnchors
	}
	return 2
}

func (t *Directory[C]) receiptTTL(tier string) time.Duration {
	if tier == "memory" {
		return min(t.ttl, MemoryTTL)
	}
	return t.ttl
}

func TierBoundaryKey(routeKey []byte, plan Plan, anchor protocol.PrefixCacheAnchor, tier string) string {
	return TierKey(BoundaryKey(routeKey, plan, anchor), tier)
}

// The keyed content digest is shared; tier namespaces keep independent holder
// limits, expiration, sequence and durability evidence. The separator cannot
// appear in the base64url content digest.
func TierKey(contentKey, tier string) string {
	if contentKey == "" || !ValidTier(tier) {
		return ""
	}
	if tier == "memory" {
		return "memory:" + contentKey
	}
	return contentKey
}
