package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *Tracker[P]) ReceiptTTL(tier string) time.Duration {
	if tier == "memory" {
		return min(t.ttl, cacheRoutingMemoryTTL)
	}
	return t.ttl
}

func CacheTierBoundaryKey(routeKey []byte, plan cacheplan.Plan, anchor protocol.PrefixCacheAnchor, tier string) string {
	return CacheTierKey(plan.BoundaryKey(routeKey, anchor), tier)
}

// The keyed content digest is shared; tier namespaces keep independent holder
// limits, expiration, sequence and durability evidence. The separator cannot
// appear in the base64url content digest.
func CacheTierKey(contentKey, tier string) string {
	if contentKey == "" || !cachepolicy.Tier(tier) {
		return ""
	}
	if tier == "memory" {
		return "memory:" + contentKey
	}
	return contentKey
}
