package firstcontent

import "github.com/eigeninference/d-inference/coordinator/registry"

// ReleaseUnsent rejects speculative empty completion before returning an
// unsent attempt's reserved slot. It does not claim or settle a terminal.
func ReleaseUnsent(reg *registry.Registry, provider *registry.Provider, pr *registry.PendingRequest) {
	if provider == nil || pr == nil {
		return
	}
	pr.ResolveSpeculativeEmptyCompletion(false)
	provider.RemovePending(pr.RequestID)
	reg.SetProviderIdle(provider.ID)
}
