package cacheplan

import (
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const BoundarySerialization = "prefix-v4"

// BoundaryKey identifies reusable content, independent of which provider holds
// it. Epochs are validated holder metadata: putting one in this key would split
// identical prefixes into separate buckets and bypass the holder bound.
func (p Plan) BoundaryKey(routeKey []byte, anchor protocol.PrefixCacheAnchor) string {
	if len(routeKey) == 0 || !p.Present() ||
		!cachepolicy.Anchor(anchor, promptcontract.BlockSize) {
		return ""
	}
	return cacheactivation.OpaqueHMAC(
		routeKey,
		BoundarySerialization,
		p.CacheScope,
		p.ModelAggregateHash,
		p.PromptContractID,
		strconv.Itoa(anchor.TokenCount),
		anchor.ChainHash,
	)
}

func (p *Plan) ObserveRouteDemand(generation *Generation, history *cachedemand.Tracker, routeKey []byte, now time.Time) {
	if p == nil || !p.Authenticates(generation) || !generation.Active() || !p.Present() {
		return
	}
	// Both reads and records use the same bounded anchor selection. Holder
	// lookup still checks every boundary in the independently verified plan.
	anchors := cachedemand.Anchors(p.Boundaries)
	boundaries := make([]cachedemand.Boundary, 0, len(anchors))
	for _, anchor := range anchors {
		key := p.BoundaryKey(routeKey, anchor)
		if key != "" {
			boundaries = append(boundaries, cachedemand.Boundary{Key: key, Tokens: anchor.TokenCount})
		}
	}
	p.ObserveDemand(history, boundaries, now)
}
