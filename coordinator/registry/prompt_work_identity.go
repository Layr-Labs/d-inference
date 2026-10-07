package registry

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/promptidentity"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// providerPromptWorkIdentityLocked binds count evidence to this candidate's
// actual renderer. The loaded-slot identity is authoritative; older providers
// can establish the same pair through their validated cache capabilities.
// Missing or conflicting evidence never borrows the request's own contract.
func providerPromptWorkIdentityLocked(p *Provider, model string) (string, string) {
	var disk, memory *protocol.PrefixCacheV2Capability
	if capability, ok := p.PrefixCacheV2Models[model]; ok {
		disk = &capability
	}
	if capability, ok := p.PrefixCacheMemoryModels[model]; ok {
		memory = &capability
	}
	return promptidentity.Resolve(model, p.Models, p.BackendCapacity, disk, memory)
}
