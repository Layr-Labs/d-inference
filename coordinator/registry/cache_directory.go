package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/cachedirectory"
)

// directoryPlan carries the same immutable exact-boundary facts and generation.
func directoryPlan(plan CachePlan) cachedirectory.Plan {
	return cachedirectory.Plan{
		Generation: plan.generation, ModelAggregateHash: plan.ModelAggregateHash,
		PromptContractID: plan.PromptContractID, CacheScope: plan.CacheScope,
		PromptTokenCount: plan.PromptTokenCount, Boundaries: plan.Boundaries,
	}
}
func (t *cacheRoutingTracker) matchingHolders(plan CachePlan, routeKey []byte, mode string, now time.Time) []cacheRoutingMatch {
	if t == nil {
		return nil
	}
	return t.directory.MatchingHolders(directoryPlan(plan), routeKey, mode, now)
}
func cacheBoundaryKey(key []byte, plan CachePlan, anchor protocol.PrefixCacheAnchor) string {
	return cachedirectory.BoundaryKey(key, directoryPlan(plan), anchor)
}
func cacheTierBoundaryKey(key []byte, plan CachePlan, anchor protocol.PrefixCacheAnchor, tier string) string {
	return cachedirectory.TierBoundaryKey(key, directoryPlan(plan), anchor, tier)
}
func validCacheReceiptTier(tier string) bool { return cachedirectory.ValidTier(tier) }
func validV2Anchor(anchor protocol.PrefixCacheAnchor, size uint32) bool {
	return cachedirectory.ValidAnchor(anchor, size)
}
func validLowerHex256(value string) bool { return cachedirectory.ValidLowerHex256(value) }
func cacheEvidenceWeight(holder cacheHolder, now time.Time) float64 {
	return cachedirectory.EvidenceWeight(holder, now)
}
func hmacBytes(key []byte, parts ...[]byte) []byte  { return cachedirectory.HMACBytes(key, parts...) }
func opaqueHMAC(key []byte, parts ...string) string { return cachedirectory.OpaqueHMAC(key, parts...) }
