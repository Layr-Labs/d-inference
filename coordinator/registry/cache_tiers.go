package registry

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (p *Provider) prefixCacheCapabilityLocked(model, tier string) (protocol.PrefixCacheV2Capability, bool) {
	switch tier {
	case "memory":
		capability, ok := p.PrefixCacheMemoryModels[model]
		return capability, ok
	case "ssd", "": // Empty is the historical SSD routing-hint representation.
		capability, ok := p.PrefixCacheV2Models[model]
		return capability, ok
	default:
		return protocol.PrefixCacheV2Capability{}, false
	}
}

func capabilityMatchesPlan(capability protocol.PrefixCacheV2Capability, plan CachePlan) bool {
	return capability.Enabled && capability.Ready &&
		capability.ModelAggregateHash == plan.ModelAggregateHash &&
		capability.PromptContractID == plan.PromptContractID
}
