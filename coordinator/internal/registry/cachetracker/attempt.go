package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type Attempt[P comparable] struct {
	RequestID             string
	ProviderID            string
	Provider              P
	Model                 string
	ExpiresAt             time.Time
	CreatedAt             time.Time
	LookupSeen            bool
	V2                    bool
	Plan                  cacheplan.Plan
	V2Capability          protocol.PrefixCacheV2Capability
	MemoryCapability      protocol.PrefixCacheV2Capability
	MemoryLookupSeen      bool
	MemoryLastReadyAnchor protocol.PrefixCacheAnchor
	ExpectedPrompt        protocol.PrefixCacheAnchor
	ExpectedBoundaries    *cacheplan.Claims
	LastReadyAnchor       protocol.PrefixCacheAnchor
}

func (a *Attempt[P]) Capability(tier string) protocol.PrefixCacheV2Capability {
	if tier == "memory" {
		return a.MemoryCapability
	}
	return a.V2Capability
}
func (a *Attempt[P]) SeenLookup(tier string) bool {
	if tier == "memory" {
		return a.MemoryLookupSeen
	}
	return a.LookupSeen
}
func (a *Attempt[P]) ReadyAnchor(tier string) protocol.PrefixCacheAnchor {
	if tier == "memory" {
		return a.MemoryLastReadyAnchor
	}
	return a.LastReadyAnchor
}
