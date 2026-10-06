package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
) // AnchorMatches compares a holder's anchor with a plan boundary. A holder
// restored from the durable copy carries only the token count: the row never
// stores the chain hash, and its key (an HMAC over the boundary) already bound
// the content, so the count is the only remaining check.
func AnchorMatches(holder, anchor protocol.PrefixCacheAnchor) bool {
	if holder.TokenCount != anchor.TokenCount {
		return false
	}
	return holder.ChainHash == "" || holder.ChainHash == anchor.ChainHash
}

// Caller holds the tracker lock after validating the Ready receipt. The keyed
// bucket binds tenant/model/content/tier; the remaining comparisons bind the
// exact connection and execution contract, including legacy replay work.
func (t *Tracker[P]) PreserveStageMeasurementLocked(
	key string, holder *Holder[P], capability protocol.PrefixCacheV2Capability, now time.Time,
) {
	previous, ok := t.ActiveHolderLocked(key, holder.ProviderID, now)
	if !ok || previous.Provider != holder.Provider || !AnchorMatches(previous.Anchor, holder.Anchor) ||
		previous.RequiredRecomputeTokens != holder.RequiredRecomputeTokens {
		return
	}
	if measured := previous.Measurement; measured != nil &&
		measured.Matches(capability) && now.Before(measured.ExpiresAt()) {
		holder.Measurement = measured
	}
}
