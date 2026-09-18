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
	if !ok || previous.Provider != holder.Provider || previous.Anchor != holder.Anchor ||
		previous.RequiredRecomputeTokens != holder.RequiredRecomputeTokens {
		return
	}
	if measured := previous.stageMeasurement; measured != nil &&
		measured.capability == capability && now.Before(measured.expiresAt) {
		holder.stageMeasurement = measured
	}
}
