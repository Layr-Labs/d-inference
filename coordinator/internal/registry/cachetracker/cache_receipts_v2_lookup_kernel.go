package cachetracker

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
) // A validated miss or shorter hit also invalidates evidence not yet restored
// into the live index. The attempt supplies its durable identity in that case.
func (t *Tracker[P]) InvalidateBoundaryLocked(key, providerID, tier, epoch string, reason RemovalReason) {
	if _, live := t.holders.Bucket(key).Load(providerID); !live && key != "" && tier == "ssd" && t.persister != nil {
		t.PersistRowAfterLossLocked(key, epoch, providerID, t.now())
	}
	t.RemoveHolderLocked(key, providerID, reason)
}

// SupersedeDeeperHoldersLocked drops this provider's holders, in the receipt's
// tier only, at every verified plan boundary deeper than the one it just
// proved. Both provider stores search longest-first, so a shorter hit means
// the provider will not deliver the deeper boundary for this prefix: the file
// was evicted or expired, a block failed authentication, or a stage cap
// trimmed the run. The receipt cannot tell those apart and no miss will ever
// fire, so without this the stale holder keeps the larger credit until its
// TTL and can outrank a machine that really holds the deeper boundary.
//
// Holders are advisory: a later ready or hit re-teaches a boundary that is
// still stored. This never fences, never touches sequence watermarks, and
// leaves every other provider's holder at those boundaries in place. Keys are
// content-addressed, so a deeper holder that belongs to a different
// continuation of the same prefix is not in this plan and is not removed.
func (t *Tracker[P]) SupersedeDeeperHoldersLocked(
	providerID string, plan cacheplan.Plan, matched protocol.PrefixCacheAnchor,
	tier, epoch string, routeKey []byte,
) {
	for _, boundary := range plan.Boundaries {
		if boundary.TokenCount <= matched.TokenCount {
			continue
		}
		if key := CacheTierBoundaryKey(routeKey, plan, boundary, tier); key != "" {
			t.InvalidateBoundaryLocked(key, providerID, tier, epoch, cacheHolderRemovalShorterHit)
		}
	}
}
