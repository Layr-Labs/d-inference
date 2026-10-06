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

// ObserveRouteDemand records the plan's boundaries in the demand history and
// reads what earlier plans shared. It also prepares a novel prompt for its own
// follow-up when the prompt holds at least firstSightMinTokens tokens; 0 never
// does. It reports whether the plan received FirstSightTokens.
func (p *Plan) ObserveRouteDemand(generation *Generation, history *cachedemand.Tracker, routeKey []byte, now time.Time, firstSightMinTokens int) bool {
	if p == nil || !p.Authenticates(generation) || !generation.Active() || !p.Present() {
		return false
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
	return p.prepareFirstSight(boundaries, firstSightMinTokens)
}

// prepareFirstSight gives a plan that observed no repeat the boundary to keep
// and the affinity key its follow-up will derive, both read from its own
// boundaries. It applies only when minTokens is positive, the prompt holds at
// least that many tokens and the plan has a stride boundary. It leaves
// RepeatedPrefixTokens at 0: the request is still reported as novel.
func (p *Plan) prepareFirstSight(boundaries []cachedemand.Boundary, minTokens int) bool {
	if minTokens <= 0 || p.RepeatedPrefixTokens != 0 || p.PromptTokenCount < minTokens {
		return false
	}
	tokens, affinity := cachedemand.FirstSight(boundaries)
	if tokens == 0 {
		return false
	}
	p.FirstSightTokens, p.affinityKey = tokens, affinity
	return true
}
