// Package cacheplan authenticates sidecar-derived cache plans to one routing
// generation without retaining the generation's receipt evidence.
package cacheplan

import (
	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type Generation struct{ revoked atomic.Bool }

func (g *Generation) Active() bool { return g != nil && !g.revoked.Load() }
func (g *Generation) Retire()      { g.revoked.Store(true) }

type Identity struct {
	ModelAggregateHash string
	PromptContractID   string
	CacheScope         string
}

type Content struct {
	Identity
	PromptTokenCount int
	Boundaries       []protocol.PrefixCacheAnchor
}

// Accepted is immutable provenance for the returned sidecar content. It carries
// no tracker evidence or mutable plan geometry.
type Accepted struct {
	generation *Generation
}

func (p Accepted) HasOrigin() bool { return p.generation != nil }
func (p Accepted) Active() bool    { return p.generation.Active() }
func (p Accepted) Authenticates(g *Generation) bool {
	return p.generation != nil && p.generation == g
}

// AcceptSidecar is the production sidecar-result operation. It does not bind an
// arbitrary caller-created cache plan. Retirement fences its later use through
// Active; the registry retains its existing post-IO current-generation check.
func AcceptSidecar(g *Generation, identity Identity, sidecar promptcontract.Plan) (Accepted, Content, bool) {
	if g == nil || !sidecar.Participating || len(sidecar.BlockBoundaries) == 0 {
		return Accepted{}, Content{}, false
	}
	boundaries := make([]protocol.PrefixCacheAnchor, 0, len(sidecar.BlockBoundaries))
	for _, boundary := range sidecar.BlockBoundaries {
		anchor := protocol.PrefixCacheAnchor{TokenCount: int(boundary.TokenCount), ChainHash: boundary.ChainHash}
		if !cachepolicy.Anchor(anchor, promptcontract.BlockSize) {
			return Accepted{}, Content{}, false
		}
		boundaries = append(boundaries, anchor)
	}
	return Accepted{generation: g}, Content{Identity: identity,
		PromptTokenCount: int(sidecar.PromptTokenCount), Boundaries: boundaries}, true
}
