package dispatch

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func cacheTelemetryPending(id string) *registry.PendingRequest {
	return &registry.PendingRequest{
		RequestID:          id,
		CachePlan:          testCachePlan("secret-route-" + id),
		CacheSelectionMode: "active", CacheSelectionTier: "ssd",
		CacheSelectionSelected: true,
	}
}

func testCachePlan(secret string) registry.CachePlan {
	return registry.CachePlan{
		ModelAggregateHash: secret,
		PromptContractID:   "contract",
		CacheScope:         "scope",
		PromptTokenCount:   64,
		Boundaries: []protocol.PrefixCacheAnchor{{
			TokenCount: 64,
			ChainHash:  strings.Repeat("a", 64),
		}},
	}
}
