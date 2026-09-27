package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Tiers share the nonce and independently verified prompt plan, but never
// share publication, sequence, epoch, or durability claims.
func validCacheReceiptTier(tier string) bool {
	return tier == "ssd" || tier == "memory"
}

func (p *Provider) prefixCacheCapabilityLocked(model, tier string) (protocol.PrefixCacheV2Capability, bool) {
	switch tier {
	case "memory":
		capability, ok := p.PrefixCacheMemoryModels[model]
		return capability, ok
	case "ssd", "": // Empty is the historical SSD routing-hint representation.
		capability, ok := p.PrefixCacheV2Models[model]
		return capability, ok
	default:
		return protocol.PrefixCacheV2Capability{}, false
	}
}

func capabilityMatchesPlan(capability protocol.PrefixCacheV2Capability, plan CachePlan) bool {
	return capability.Enabled && capability.Ready &&
		capability.ModelAggregateHash == plan.ModelAggregateHash &&
		capability.PromptContractID == plan.PromptContractID
}

func (attempt *cacheAttempt) capability(tier string) protocol.PrefixCacheV2Capability {
	if tier == "memory" {
		return attempt.MemoryCapability
	}
	return attempt.V2Capability
}

func (attempt *cacheAttempt) lookupSeen(tier string) bool {
	if tier == "memory" {
		return attempt.MemoryLookupSeen
	}
	return attempt.LookupSeen
}

func (attempt *cacheAttempt) lastReadyAnchor(tier string) protocol.PrefixCacheAnchor {
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
		return cacheRoutingMaxCheckpointReadyAnchors
	}
	return 2
}

func (t *cacheRoutingTracker) receiptTTL(tier string) time.Duration {
	if tier == "memory" {
		return min(t.ttl, cacheRoutingMemoryTTL)
	}
	return t.ttl
}

func cacheTierBoundaryKey(routeKey []byte, plan CachePlan, anchor protocol.PrefixCacheAnchor, tier string) string {
	return cacheTierKey(cacheBoundaryKey(routeKey, plan, anchor), tier)
}

// The keyed content digest is shared; tier namespaces keep independent holder
// limits, expiration, sequence and durability evidence. The separator cannot
// appear in the base64url content digest.
func cacheTierKey(contentKey, tier string) string {
	if contentKey == "" || !validCacheReceiptTier(tier) {
		return ""
	}
	if tier == "memory" {
		return "memory:" + contentKey
	}
	return contentKey
}
