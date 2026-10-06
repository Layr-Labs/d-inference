package cacheplan

import (
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Plan carries request-local content metadata and immutable sidecar provenance.
// Advisory demand never supplies cache credit or bypasses receipt proof.
type Plan struct {
	RepeatedPrefixTokens int
	affinityKey          string
	origin               Accepted
	ModelAggregateHash   string
	PromptContractID     string
	CacheScope           string
	PromptTokenCount     int
	Boundaries           []protocol.PrefixCacheAnchor
	// FirstSightTokens is the boundary a novel prompt asks its provider to
	// keep for a follow-up. It is set only while RepeatedPrefixTokens is 0
	// and is never evidence of a repeat.
	FirstSightTokens int
}

func (p Plan) Present() bool {
	return p.ModelAggregateHash != "" && p.PromptContractID != "" && p.CacheScope != "" &&
		p.PromptTokenCount > 0 && len(p.Boundaries) > 0
}
func (p Plan) HasOrigin() bool                  { return p.origin.HasOrigin() }
func (p Plan) Authenticates(g *Generation) bool { return p.origin.Authenticates(g) }
func (p Plan) Provenance() Accepted             { return p.origin }
func (p Plan) AffinityKey() string              { return p.affinityKey }

// RetainedPrefixTokens is the depth sent to the provider, which keeps the
// checkpoint at or below it and writes this request's checkpoints only when it
// is at least one stride.
func (p Plan) RetainedPrefixTokens() int {
	return max(0, p.RepeatedPrefixTokens, p.FirstSightTokens)
}

// Detached copies every string and the boundary slice, so retaining the result
// keeps none of the caller's storage alive. Provenance is unchanged.
func (p Plan) Detached() Plan {
	p.affinityKey = strings.Clone(p.affinityKey)
	p.ModelAggregateHash = strings.Clone(p.ModelAggregateHash)
	p.PromptContractID = strings.Clone(p.PromptContractID)
	p.CacheScope = strings.Clone(p.CacheScope)
	boundaries := make([]protocol.PrefixCacheAnchor, len(p.Boundaries))
	for i, boundary := range p.Boundaries {
		boundary.ChainHash = strings.Clone(boundary.ChainHash)
		boundaries[i] = boundary
	}
	p.Boundaries = boundaries
	return p
}

func PlanFromSidecar(g *Generation, identity Identity, sidecar promptcontract.Plan) (Plan, bool) {
	origin, content, accepted := AcceptSidecar(g, identity, sidecar)
	if !accepted {
		return Plan{}, false
	}
	return Plan{origin: origin, ModelAggregateHash: content.ModelAggregateHash,
		PromptContractID: content.PromptContractID, CacheScope: content.CacheScope,
		PromptTokenCount: content.PromptTokenCount, Boundaries: content.Boundaries}, true
}

// ObserveDemand records the real derived boundaries before updating advisory
// metadata. The actual bounded history remains the sole owner of repetition.
// It clears FirstSightTokens, which described the plan before this observation
// and must not outlive a repeat.
func (p *Plan) ObserveDemand(history *cachedemand.Tracker, boundaries []cachedemand.Boundary, now time.Time) {
	p.RepeatedPrefixTokens, p.affinityKey = history.Observe(boundaries, now)
	p.FirstSightTokens = 0
}
