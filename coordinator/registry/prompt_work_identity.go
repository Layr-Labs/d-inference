package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// providerPromptWorkIdentityLocked binds count evidence to this candidate's
// actual renderer. The loaded-slot identity is authoritative; older providers
// can establish the same pair through their validated cache capabilities.
// Missing or conflicting evidence never borrows the request's own contract.
func providerPromptWorkIdentityLocked(p *Provider, model string) (string, string) {
	artifact := ""
	for _, advertised := range p.Models {
		if advertised.ID == model {
			artifact = strings.ToLower(strings.TrimSpace(advertised.WeightHash))
			break
		}
	}
	if !validLowerHex256(artifact) {
		return "", ""
	}
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			if !slotStateModelLoaded(slot.State) {
				return "", ""
			}
			if identity := slot.PromptWorkIdentity; identity != nil {
				if !identity.IsValid() || identity.ModelArtifactHash != artifact {
					return "", ""
				}
				return artifact, identity.PromptContractID
			}
		}
	}
	contract := ""
	for _, capabilities := range []map[string]protocol.PrefixCacheV2Capability{p.PrefixCacheV2Models, p.PrefixCacheMemoryModels} {
		capability, ok := capabilities[model]
		if !ok {
			continue
		}
		if !capability.Enabled || !capability.Ready || capability.ModelAggregateHash != artifact || !validLowerHex256(capability.PromptContractID) {
			return "", ""
		}
		if contract != "" && contract != capability.PromptContractID {
			return "", ""
		}
		contract = capability.PromptContractID
	}
	if contract == "" {
		return "", ""
	}
	return artifact, contract
}
