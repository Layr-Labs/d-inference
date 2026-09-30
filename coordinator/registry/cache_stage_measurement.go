package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// An immutable lookup observation, shared only by refreshes of its exact
// holder. Ready renews cache availability, never this measurement's deadline.
type cacheStageMeasurement struct {
	milliseconds float64
	expiresAt    time.Time
	capability   protocol.PrefixCacheV2Capability
}

// anchorMatches compares a holder's anchor with a plan boundary. A holder
// restored from the durable copy carries only the token count: the row never
// stores the chain hash, and its key (an HMAC over the boundary) already bound
// the content, so the count is the only remaining check.
func anchorMatches(holder, anchor protocol.PrefixCacheAnchor) bool {
	if holder.TokenCount != anchor.TokenCount {
		return false
	}
	return holder.ChainHash == "" || holder.ChainHash == anchor.ChainHash
}

func (h cacheHolder) stageCostAt(now time.Time) float64 {
	if measured := h.stageMeasurement; measured != nil && now.Before(measured.expiresAt) {
		return measured.milliseconds
	}
	return h.StageMs
}

// Caller holds the tracker lock after validating the Ready receipt. The keyed
// bucket binds tenant/model/content/tier; the remaining comparisons bind the
// exact connection and execution contract, including legacy replay work.
func (t *cacheRoutingTracker) preserveStageMeasurementLocked(
	key string, holder *cacheHolder, capability protocol.PrefixCacheV2Capability, now time.Time,
) {
	previous, ok := t.activeHolderLocked(key, holder.ProviderID, now)
	if !ok || previous.Provider != holder.Provider || !anchorMatches(previous.Anchor, holder.Anchor) ||
		previous.RequiredRecomputeTokens != holder.RequiredRecomputeTokens {
		return
	}
	if measured := previous.stageMeasurement; measured != nil &&
		measured.capability == capability && now.Before(measured.expiresAt) {
		holder.stageMeasurement = measured
	}
}
