package cachedirectory

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type Holder[C comparable] struct {
	ProviderID              string
	Provider                C
	ModelID                 string
	ModelAggregateHash      string
	PromptContractID        string
	CacheEpoch              string
	Anchor                  protocol.PrefixCacheAnchor
	RequiredRecomputeTokens int
	StageMs                 float64
	stageMeasurement        *cacheStageMeasurement
	UpdatedAt               time.Time
	ExpiresAt               time.Time
}

type Attempt[C comparable] struct {
	RequestID             string
	ProviderID            string
	Provider              C
	Model                 string
	ExpiresAt             time.Time
	CreatedAt             time.Time
	LookupSeen            bool
	V2                    bool
	Plan                  Plan
	V2Capability          protocol.PrefixCacheV2Capability
	MemoryCapability      protocol.PrefixCacheV2Capability
	MemoryLookupSeen      bool
	MemoryLastReadyAnchor protocol.PrefixCacheAnchor
	ExpectedPrompt        protocol.PrefixCacheAnchor
	ExpectedBoundaries    map[int]string
	LastReadyAnchor       protocol.PrefixCacheAnchor
}

type cacheV2SequenceKey struct {
	ProviderID string
	ModelID    string
	CacheEpoch string
	Tier       string
}

type cacheV2ProviderModelKey struct {
	ProviderID string
	ModelID    string
	Tier       string
}
