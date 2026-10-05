// Package promptidentity binds prompt counts to the advertised artifact and renderer.
package promptidentity

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Resolve gives the loaded engine authority over legacy cache capabilities.
// Absent, malformed or conflicting evidence cannot borrow the request identity.
func Resolve(model string, models []protocol.ModelInfo, capacity *protocol.BackendCapacity, disk, memory *protocol.PrefixCacheV2Capability) (string, string) {
	artifact := ""
	for _, advertised := range models {
		if advertised.ID == model {
			artifact = strings.ToLower(strings.TrimSpace(advertised.WeightHash))
			break
		}
	}
	if !cachepolicy.LowerHex256(artifact) {
		return "", ""
	}
	if capacity != nil {
		for _, slot := range capacity.Slots {
			if slot.Model != model {
				continue
			}
			if slot.State != "running" && slot.State != "idle" {
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
	for _, capability := range []*protocol.PrefixCacheV2Capability{disk, memory} {
		if capability == nil {
			continue
		}
		if !capability.Enabled || !capability.Ready || capability.ModelAggregateHash != artifact || !cachepolicy.LowerHex256(capability.PromptContractID) {
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
