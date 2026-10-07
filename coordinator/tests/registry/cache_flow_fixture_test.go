package registry_test

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func cacheFlowAnchor(blocks int, hexByte string) protocol.PrefixCacheAnchor {
	return protocol.PrefixCacheAnchor{TokenCount: blocks * int(promptcontract.BlockSize), ChainHash: strings.Repeat(hexByte, 64)}
}

func cacheFlowPlan(boundaries ...protocol.PrefixCacheAnchor) production.CachePlan {
	return production.CachePlan{
		ModelAggregateHash: strings.Repeat("a", 64), PromptContractID: strings.Repeat("b", 64), CacheScope: "opaque-scope",
		PromptTokenCount: boundaries[len(boundaries)-1].TokenCount, Boundaries: boundaries,
	}
}
