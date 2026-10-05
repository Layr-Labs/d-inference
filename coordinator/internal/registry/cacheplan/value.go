package cacheplan

import (
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
}

func (p Plan) Present() bool {
	return p.ModelAggregateHash != "" && p.PromptContractID != "" && p.CacheScope != "" &&
		p.PromptTokenCount > 0 && len(p.Boundaries) > 0
}
func (p Plan) HasOrigin() bool                  { return p.origin.HasOrigin() }
func (p Plan) Authenticates(g *Generation) bool { return p.origin.Authenticates(g) }
func (p Plan) Provenance() Accepted             { return p.origin }
func (p Plan) AffinityKey() string              { return p.affinityKey }

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
func (p *Plan) ObserveDemand(history *cachedemand.Tracker, boundaries []cachedemand.Boundary, now time.Time) {
	p.RepeatedPrefixTokens, p.affinityKey = history.Observe(boundaries, now)
}
